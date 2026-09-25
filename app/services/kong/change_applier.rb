module Kong
  # Executes a pending ChangePlan -- docs/DESIGN.md section 10, steps 6
  # ("Execute") and 7 ("Record"). Re-runs guardrails (state may have moved
  # since the plan was proposed), checks the plan's expiry and its
  # optimistic lock, then either writes through to Kong (`apply_mode:
  # direct`) or renders + pushes a decK YAML branch (`apply_mode: pr`,
  # docs/DESIGN.md section 6) -- never both, and never mutates a plan that
  # isn't pending.
  class ChangeApplier
    BRANCH_PREFIX = "kongctl"

    Result = Struct.new(:change_plan, :audit_event, keyword_init: true)

    def initialize(change_plan:, client:, actor_username:, actor_operator: nil, confirmation_name: nil, secret: nil,
                    env_acknowledged: false)
      @change_plan = change_plan
      @connection = change_plan.kong_connection
      @client = client
      @actor_username = actor_username
      @actor_operator = actor_operator
      @confirmation_name = confirmation_name
      @secret = secret
      @env_acknowledged = env_acknowledged == true
      @env_vars = []
      @definition = Kong::EntityTypes.fetch(change_plan.entity_type)
    end

    def call
      raise Kong::ChangeGuardrails::Violation, "this plan is #{@change_plan.status}, not pending" unless @change_plan.status == "pending"
      raise Kong::ChangeGuardrails::Violation, "this plan expired -- re-propose the change" if @change_plan.expired?

      Kong::ChangeGuardrails.check_write_access!(connection: @connection)
      Kong::ChangeGuardrails.check_plan_mode_current!(plan: @change_plan, connection: @connection)
      Kong::ChangeGuardrails.check_plugin_immutable!(
        connection: @connection, entity_type: @change_plan.entity_type,
        target: @change_plan.operation == "create" ? nil : { "id" => @change_plan.target_kong_id },
        scope_kong_id: @change_plan.operation == "create" ? @change_plan.parent_kong_id : nil
      )

      # M5b: re-check the key policy against the *current* apply_mode (a plan
      # can sit pending 15 minutes) and demand the env-var acknowledgement.
      Kong::CertificateKeyPolicy.check!(
        @change_plan.after, entity_type: @change_plan.entity_type, apply_mode: @connection.apply_mode,
        operation: @change_plan.operation
      )
      require_env_acknowledgement!

      if @change_plan.operation == "delete"
        Kong::ChangeGuardrails.check_delete_confirmation!(
          connection: @connection, entity: @change_plan.before, confirmation_name: @confirmation_name,
          actor_kind: @change_plan.actor_kind
        )
      end

      # An admin-path entity must never reach decK YAML at all (rule ง) --
      # blocked here, before anything is rendered, rather than filtered out
      # at serialize time.
      if @change_plan.apply_mode == "pr" && @connection.admin_path?(@change_plan.target_kong_id)
        raise Kong::ChangeGuardrails::Violation, "this entity is on the admin path -- it is never rendered into decK YAML"
      end

      check_optimistic_lock! unless @change_plan.operation == "create"

      execute!
    rescue Kong::Client::Error, Kong::GitClient::Error, Kong::DeckCli::Error => e
      # Keep the failing side's own words on the plan, not just in the flash
      # that dies on the next request -- a reviewer opening this plan later
      # needs to know why it failed.
      @change_plan.update!(status: "failed", failure_reason: failure_reason_for(e))
      raise e
    end

    private

    # A stored reason is read back by every operator who opens the plan, for as
    # long as the plan exists, so it goes through the same bar as anything else
    # entering the read-model (docs/DESIGN.md section 8).
    FAILURE_REASON_LIMIT = 2000
    # `https://user:token@host/repo.git` -- git echoes the remote it was given
    # in its own stderr, and `run!` puts the argv in the message, so a config
    # repo URL carrying a token would otherwise be persisted verbatim.
    URL_CREDENTIAL = %r{://[^/\s@]+@}

    def failure_reason_for(error)
      text = [ error.message, kong_detail(error) ].compact_blank.join(" -- ")

      Kong::CertificateKeyPolicy.scrub(text)
        .gsub(URL_CREDENTIAL, "://")
        .truncate(FAILURE_REASON_LIMIT)
    end

    # Kong::Client raises a classification of the status ("unexpected Kong Admin
    # API status 400"), keeping Kong's own body on the exception. The
    # classification alone cannot tell an operator *which field* Kong objected
    # to, which is the whole point of showing a reason, so the body's message
    # and field errors are appended to it.
    def kong_detail(error)
      return nil unless error.is_a?(Kong::Client::Error) && error.response

      body = error.response.body
      body = JSON.parse(body) if body.is_a?(String)
      return nil unless body.is_a?(Hash)

      [ body["message"], body["fields"].presence&.to_json ].compact_blank.join(" ")
    rescue JSON::ParserError
      nil
    end

    # A nested type (target) resolves every path through its upstream, which
    # the planner stored on the plan as parent_kong_id.
    def member_path
      @definition.member_path(@change_plan.target_kong_id, parent_kong_id: @change_plan.parent_kong_id)
    end

    def check_optimistic_lock!
      current = fetch_current
      return if @change_plan.base_updated_at.blank?
      return if current["updated_at"].blank?
      return if same_instant?(Time.zone.at(current["updated_at"]), @change_plan.base_updated_at)

      raise Kong::ChangeGuardrails::Violation,
        "this #{@change_plan.entity_type} was changed by someone else since this plan was proposed -- review the new state and re-propose"
    end

    # Most Kong entities stamp updated_at in whole seconds, but a target's
    # carries milliseconds (1789914728.226). The plan's copy has been through
    # the database's microsecond rounding while this side is a bare float, so
    # an exact == never matches for those. Milliseconds is Kong's own finest
    # resolution, so comparing there loses nothing real.
    def same_instant?(a, b)
      a.round(3) == b.round(3)
    end

    def fetch_current
      response = @client.get(member_path)
      body = response.body
      body.is_a?(String) ? JSON.parse(body) : body
    end

    def execute!
      if @change_plan.apply_mode == "pr"
        execute_pr_discarding_unsaved_id!
      else
        case @change_plan.operation
        when "create" then execute_create!
        when "update" then execute_update!
        when "delete" then execute_delete!
        end
      end

      @change_plan.update!(status: "applied")
      audit_event = record_audit_event!

      Result.new(change_plan: @change_plan, audit_event: audit_event)
    end

    def execute_create!
      response = @client.post(@definition.create_path(parent_kong_id: @change_plan.parent_kong_id), body: @change_plan.after)
      raw = parse(response)
      entity = Kong::EntitySync.new(connection: @connection, client: @client, entity_type: @change_plan.entity_type).upsert(raw)
      refresh_parent_certificate(entity.parent_kong_id) if @change_plan.entity_type == "sni"
    end

    # Sends only the fields that actually changed, not the whole merged
    # document. Kong's PATCH is a partial update, and echoing its own GET
    # payload back at it is both needless and unsafe: a key-auth credential
    # comes back with `ttl: null`, which Kong 3.7 then 500s on when it is
    # written back. Sending the diff also means a field someone else changed
    # between propose and apply is left alone rather than clobbered with the
    # value this plan happened to read.
    def execute_update!
      body = @change_plan.diff.each_with_object({}) { |(field, change), acc| acc[field] = change["to"] }
      response = @client.patch(member_path, body: body)
      raw = parse(response)
      entity = Kong::EntitySync.new(connection: @connection, client: @client, entity_type: @change_plan.entity_type).upsert(raw)
      refresh_parents_after_sni_update(entity) if @change_plan.entity_type == "sni"
    end

    # Re-pointing an SNI moves it between certificates: the new parent gains a
    # name/SNI and the old one loses it, so both need refreshing.
    def refresh_parents_after_sni_update(entity)
      refresh_parent_certificate(entity.parent_kong_id)
      previous = @change_plan.before.dig("certificate", "id")
      refresh_parent_certificate(previous) if previous.present? && previous != entity.parent_kong_id
    end

    def execute_delete!
      @client.delete(member_path)
      KongEntity.active
        .where(kong_connection: @connection, entity_type: @change_plan.entity_type, kong_id: @change_plan.target_kong_id)
        .update_all(deleted_at: Time.current)
      soft_delete_children
      refresh_parent_certificate(@change_plan.before.dig("certificate", "id") || @change_plan.parent_kong_id) if @change_plan.entity_type == "sni"
    end

    # Kong accepts a broken {vault://env/...} reference silently and the
    # hostname's TLS then fails (M5b spec section 1), and this tool cannot see
    # Kong's environment. So the operator (or agent) must state, out of band,
    # that the variable exists on every node.
    def require_env_acknowledgement!
      @env_vars = Kong::CertificateKeyPolicy.env_vars_for(@change_plan)
      return if @env_vars.empty? || @env_acknowledged

      raise Kong::ChangeGuardrails::Violation,
        "this makes Kong read #{@env_vars.join(', ')} -- confirm that variable is set on every Kong node " \
        "(acknowledge_env_vars) before applying; Kong won't notice if it is missing"
    end

    # After a child write, the parent's derived name/logical_key may have moved
    # (a certificate is named by its first SNI). The write already happened, so
    # a failed refresh must not fail the apply -- the next sync corrects it.
    def refresh_parent_certificate(parent_kong_id)
      return if parent_kong_id.blank?

      Kong::EntitySync.sync_one(connection: @connection, client: @client, entity_type: "certificate", kong_id: parent_kong_id)
    rescue Kong::Client::Error, JSON::ParserError, KeyError, ActiveRecord::ActiveRecordError => e
      Rails.logger.warn("kong: parent certificate refresh failed after a child write (#{e.class}: #{e.message})")
      nil
    end

    # Kong deletes a certificate's SNIs and an upstream's targets with it;
    # without this the read-model would keep listing them until the next sync.
    def soft_delete_children
      KongEntity.active
        .where(kong_connection: @connection, parent_kong_id: @change_plan.target_kong_id)
        .update_all(deleted_at: Time.current)
    end

    # The renderer mints a certificate create's id onto the plan in memory. If
    # anything after that raises, nothing was pushed, so the id must not be
    # written by whatever saves the plan next (the rescue that marks it failed).
    def execute_pr_discarding_unsaved_id!
      execute_pr!
    rescue StandardError
      @change_plan.restore_attributes(%w[target_kong_id])
      raise
    end

    # docs/DESIGN.md section 6, "เส้นทางของ PR mode" steps 2-8: pull the
    # config repo, refuse a file the tool could not reproduce, mutate + serialize
    # its YAML (rules ก-ค), validate + diff against Kong with the read-only
    # credential already in hand, commit to a branch, and push. No PR-host API
    # call -- see Kong::GitClient. Everything that can refuse does so before the
    # branch is touched: the repo is left clean and the plan stays pending.
    def execute_pr!
      Kong::DeckRenderer.assert_supported!(@change_plan.entity_type)
      require_select_tags!

      git = Kong::GitClient.new(connection: @connection).pull!

      text = read_yaml(git)
      Kong::DeckDocument.verify_input!(text)
      doc = Kong::DeckDocument.parse(text, select_tags: @connection.select_tags)
      Kong::DeckRenderer.apply_change(doc, @change_plan)
      rendered = Kong::DeckDocument.serialize(doc)
      verify_round_trip!(rendered)

      branch = "#{BRANCH_PREFIX}/#{@change_plan.id}"
      git.checkout_branch!(branch)
      git.write_file(@connection.git_path, rendered)

      file_path = git.working_dir.join(@connection.git_path)
      Kong::DeckCli.validate(file_path)
      deck_diff = Kong::DeckCli.diff(file_path, connection: @connection, secret: @secret)

      commit_sha = git.commit!(commit_message, author_name: @actor_username)
      git.push!(branch)

      # A certificate create's minted id (target_kong_id) was assigned in memory
      # by Kong::DeckRenderer; it is written only here, once the branch is pushed.
      @change_plan.update!(commit_sha: commit_sha, deck_diff: deck_diff, pr_state: "branch_pushed",
        target_kong_id: @change_plan.target_kong_id)
    end

    # decK reads an empty `select_tags` as "no filter": `deck gateway sync` would
    # then treat the whole workspace as managed and delete everything the file
    # does not list. So a PR-mode connection must name its tags; refused before
    # the repo is pulled. (Kong::DeckDocument writes `select_tags: []` faithfully;
    # this is the enforcement point.)
    def require_select_tags!
      return if Array(@connection.select_tags).map(&:to_s).reject(&:blank?).any?

      raise Kong::ChangeGuardrails::Violation,
        "this connection has no select_tags -- decK would sync the whole workspace and delete everything absent from " \
        "the config file; set select_tags on the connection first"
    end

    def read_yaml(git)
      path = git.working_dir.join(@connection.git_path)
      File.exist?(path) ? File.read(path) : nil
    end

    def verify_round_trip!(rendered)
      Kong::DeckDocument.verify_input!(rendered)
    rescue Kong::DeckDocument::Unparseable => e
      # e.message names only a line number (never a value), so an operator can see
      # where a serializer bug bites.
      raise Kong::ChangeGuardrails::Violation,
        "rendered YAML did not round-trip byte-for-byte (#{e.message}) -- refusing to push a diff that would be noisy to review"
    end

    def commit_message
      summary = "#{@change_plan.operation} #{@change_plan.entity_type} #{@change_plan.entity_label}"
      lines = [ summary, "", "Plan: #{@change_plan.id}" ]
      lines << "Changed-by: #{@actor_operator}" if @actor_operator.present?
      lines.join("\n")
    end

    def parse(response)
      body = response.body
      body.is_a?(String) ? JSON.parse(body) : body
    end

    def record_audit_event!
      AuditEvent.create!(
        kong_connection: @connection,
        change_plan: @change_plan,
        actor_username: @actor_username,
        actor_operator: @actor_operator,
        actor_kind: @change_plan.actor_kind,
        operation: @change_plan.operation,
        entity_type: @change_plan.entity_type,
        target_kong_id: @change_plan.target_kong_id,
        entity_name: @change_plan.entity_label,
        diff: @change_plan.diff,
        context: @env_vars.present? ? { "acknowledged_env_vars" => @env_vars } : {}
      )
    end
  end
end
