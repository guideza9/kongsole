module Kong
  # R8.6: the one way a PR-mode change leaves Kongsole (docs/DESIGN.md section
  # 6, PR-mode steps 2-8, for a whole changeset). Everything that can refuse
  # does so before the branch is pushed -- and then git is left clean, the
  # changeset stays open and its items stay pending, with the reason kept on
  # the changeset. Only a person submits (the agent path adds items; R8.7).
  # Kong is only read: decK diffs through the read-only credential.
  class ChangesetSubmitter
    BRANCH_PREFIX = "kongctl/changeset-"

    def initialize(changeset:, client:, secret:, actor_username:, actor_operator:, acknowledge_drift: false,
                    env_acknowledged: false)
      @changeset = changeset
      @connection = changeset.kong_connection
      @client = client
      @secret = secret
      @actor_username = actor_username
      @actor_operator = actor_operator
      @acknowledge_drift = acknowledge_drift == true
      @env_acknowledged = env_acknowledged == true
      @renderer = Kong::ChangesetRenderer.new(changeset: changeset, secret: secret)
      @env_vars = {}
    end

    def call
      check_submittable!
      git = Kong::GitClient.new(connection: @connection).pull!
      check_drift!(git)

      rendered = @renderer.render!(git)
      git.write_file(@connection.git_path, rendered)
      file = git.working_dir.join(@connection.git_path)
      extra = @renderer.extra_paths(git)
      Kong::DeckCli.validate(file, extra_paths: extra)
      deck_diff = Kong::DeckCli.diff(file, connection: @connection, secret: @secret, extra_paths: extra)
      gate = @renderer.gate_for(deck_diff)
      unless gate.passed?
        raise Kong::ChangeGuardrails::Violation, "the CI gate blocks this changeset: #{gate.reasons.join('; ')}"
      end

      branch = "#{BRANCH_PREFIX}#{@changeset.id}"
      git.checkout_branch!(branch)
      commit_sha = git.commit!(Kong::PrBody.commit_message(@changeset, operator: @actor_operator), author_name: @actor_username)
      git.push!(branch)

      record_submitted!(branch: branch, commit_sha: commit_sha, deck_diff: deck_diff, gate: gate)
    rescue StandardError => e
      git&.discard!
      @changeset.update_columns(failure_reason: Kong::ChangesetRenderer.scrub(e.message), updated_at: Time.current) if @changeset.open?
      raise
    end

    private

    def check_submittable!
      raise Kong::ChangeGuardrails::Violation, "this changeset is #{@changeset.status}, not open" unless @changeset.open?
      raise Kong::ChangeGuardrails::Violation, "this changeset has no items to submit" if @renderer.items.empty?

      Kong::ChangeGuardrails.check_write_access!(connection: @connection)
      @renderer.items.each { |plan| check_item!(plan) }
    end

    # Re-checked here, not only when the item was added: the admin path or
    # the key policy may have moved since (CLAUDE.md rules 3 and 4).
    def check_item!(plan)
      if @connection.admin_path?(plan.target_kong_id) || @connection.admin_path?(plan.parent_kong_id)
        raise Kong::ChangeGuardrails::Violation,
          "item #{plan.position} (#{plan.entity_type} #{plan.entity_label}) is on the admin path -- it is never rendered into decK YAML"
      end

      Kong::CertificateKeyPolicy.check!(plan.after, entity_type: plan.entity_type, apply_mode: @connection.apply_mode,
        operation: plan.operation)
      vars = Kong::CertificateKeyPolicy.env_vars_for(plan)
      @env_vars[plan.id] = vars if vars.any?
      return if vars.empty? || @env_acknowledged

      raise Kong::ChangeGuardrails::Violation,
        "item #{plan.position} makes Kong read #{vars.join(', ')} -- confirm that variable is set on every Kong node " \
        "(acknowledge_env_vars) before submitting; Kong won't notice if it is missing"
    end

    def check_drift!(git)
      drift = Kong::ChangesetDrift.check(changeset: @changeset, git: git, client: @client)
      return unless drift.any? && !@acknowledge_drift

      raise Kong::ChangeGuardrails::Violation,
        "git or Kong changed since this changeset began -- review the preview, then acknowledge the drift to submit over it"
    end

    def record_submitted!(branch:, commit_sha:, deck_diff:, gate:)
      pr_body = Kong::PrBody.markdown(@changeset, deck_diff: deck_diff, gate: gate, operator: @actor_operator)

      Changeset.transaction do
        @renderer.items.each do |plan|
          # A certificate create's minted id (target_kong_id) was assigned in
          # memory by Kong::DeckRenderer; it is written only now, once pushed.
          plan.update!(status: "applied", pr_state: "branch_pushed", commit_sha: commit_sha, target_kong_id: plan.target_kong_id)
          record_audit_event!(plan)
        end
        @changeset.update!(status: "submitted", branch: branch, commit_sha: commit_sha, deck_diff: deck_diff,
          gate_reasons: gate.reasons, pr_body: pr_body, failure_reason: nil,
          submitted_at: Time.current, submitted_by: @actor_username)
      end
      @changeset
    end

    def record_audit_event!(plan)
      context = { "changeset_id" => @changeset.id }
      context["acknowledged_env_vars"] = @env_vars[plan.id] if @env_vars[plan.id]
      AuditEvent.create!(
        kong_connection: @connection, change_plan: plan,
        actor_username: @actor_username, actor_operator: @actor_operator, actor_kind: plan.actor_kind,
        operation: plan.operation, entity_type: plan.entity_type, target_kong_id: plan.target_kong_id,
        entity_name: plan.entity_label, diff: plan.diff, context: context
      )
    end
  end
end
