module Kong
  # Proposes a create/update/delete against a live-fetched Kong entity --
  # docs/DESIGN.md section 10, step 4 ("Plan"). Runs guardrails, computes a
  # before/after/diff, and writes a pending ChangePlan for a human or an MCP
  # agent to review before anything touches Kong. Paths for any entity_type
  # come from Kong::EntityTypes (docs/DESIGN.md section 15, M3).
  #
  # `attributes` must use string keys (matching Kong's own JSON) so
  # `before.merge(attributes)` actually overrides the right fields --
  # before comes straight from JSON.parse, and a symbol key would merge in
  # as a sibling rather than an override.
  class ChangePlanner
    # The request itself is malformed -- as opposed to a guardrail refusing a
    # well-formed one. Still a Violation (existing rescues catch it), but the
    # API answers 422 rather than 403, since nothing here is about permission.
    class InvalidChange < Kong::ChangeGuardrails::Violation; end

    # Kong's own schema refused the proposed body. Distinct so a JSON editor
    # can re-render with the operator's text intact instead of redirecting.
    class SchemaViolation < InvalidChange; end

    # A nested type (target) with no parent to build its Admin API path from.
    class MissingParent < InvalidChange; end

    # Convenience fields Kong's write endpoint accepts but its schema does not
    # know: a certificate's `snis` creates the SNI rows, and `/schemas/
    # certificates/validate` answers "snis: unknown field". Left out of the
    # validation body only -- the plan's `after`, and so the apply body, keep it.
    NOT_IN_KONG_SCHEMA = { "certificate" => %w[snis] }.freeze

    def initialize(connection:, client:, operation:, entity_type:, actor_username:, target_kong_id: nil,
                    parent_kong_id: nil, attributes: {}, actor_operator: nil, actor_kind: "human", replaces_plan_id: nil)
      @connection = connection
      @client = client
      @operation = operation
      @entity_type = entity_type
      @target_kong_id = target_kong_id
      @parent_kong_id = parent_kong_id
      @attributes = attributes
      @actor_username = actor_username
      @actor_operator = actor_operator
      @actor_kind = actor_kind
      @replaces_plan_id = replaces_plan_id
      @definition = Kong::EntityTypes.fetch(entity_type)
    end

    def call
      Kong::ChangeGuardrails.check_write_access!(connection: @connection)
      Kong::CertificateKeyPolicy.check!(
        @attributes, entity_type: @entity_type, apply_mode: @connection.apply_mode, operation: @operation
      )
      Kong::ChangeGuardrails.check_plugin_immutable!(
        connection: @connection, entity_type: @entity_type,
        target: @operation == "create" ? nil : { "id" => @target_kong_id },
        scope_kong_id: @operation == "create" ? plugin_scope_kong_id : nil
      )

      @parent_kong_id = resolve_parent_kong_id
      refuse_admin_path_in_changeset! if pr_mode?

      before = @operation == "create" ? {} : fetch_current

      if @actor_kind == "agent" && @operation == "delete"
        Kong::ChangeGuardrails.check_delete_confirmation!(
          connection: @connection, entity: before, confirmation_name: nil, actor_kind: "agent"
        )
      end

      after = compute_after(before)
      validate_against_kong_schema!(after)

      pr_mode? ? create_in_changeset!(before, after) : create_plan!(before, after)
    end

    private

    def pr_mode?
      @connection.apply_mode == "pr"
    end

    def create_plan!(before, after, **changeset_fields)
      ChangePlan.create!(
        **changeset_fields,
        kong_connection: @connection,
        actor_username: @actor_username,
        actor_operator: @actor_operator,
        actor_kind: @actor_kind,
        operation: @operation,
        entity_type: @entity_type,
        target_kong_id: @target_kong_id,
        parent_kong_id: @parent_kong_id,
        before: before,
        after: after || {},
        diff: compute_diff(before, after),
        apply_mode: @connection.apply_mode,
        base_updated_at: before["updated_at"] ? Time.zone.at(before["updated_at"]) : nil,
        status: "pending",
        expires_at: ChangePlan::DEFAULT_TTL.from_now
      )
    end

    # R8.2: a PR-mode proposal is an item of the connection's open changeset,
    # never a plan of its own. An item that replaces an earlier one (an edit)
    # takes its place in the order and, for a create, its provisional id, so
    # children proposed under it still find it.
    #
    # The changeset is found (or opened) outside the transaction, then locked
    # and re-checked inside it: a submit or abandon that finished in between
    # would otherwise take an item it never rendered. One retry opens a
    # fresh changeset for it.
    def create_in_changeset!(before, after)
      2.times do
        changeset = Changeset.open_for!(connection: @connection, actor_username: @actor_username, actor_operator: @actor_operator)
        plan = ChangePlan.transaction do
          changeset.lock!
          next nil unless changeset.open?

          replaced = replaced_item(changeset)
          refuse_second_item_on_entity!(changeset, replaced)
          replaced&.update!(status: "cancelled")

          create_plan!(before, after,
            changeset: changeset,
            replaces_plan: replaced,
            position: replaced&.position || (changeset.change_plans.maximum(:position).to_i + 1),
            provisional_kong_id: (@operation == "create" ? replaced&.provisional_kong_id || SecureRandom.uuid : nil))
        end
        return plan if plan
      end
      raise Kong::ChangeGuardrails::Violation, "the changeset closed while this was being added -- propose it again"
    end

    def replaced_item(changeset)
      return nil if @replaces_plan_id.blank?

      changeset.items.find_by(id: @replaces_plan_id) ||
        raise(InvalidChange, "plan #{@replaces_plan_id} is not an item of this changeset -- it cannot be replaced")
    end

    # Two items on one entity would render the second over a `before` the
    # first already changed. The one already there is edited instead.
    def refuse_second_item_on_entity!(changeset, replaced)
      return if @target_kong_id.blank?

      other = changeset.items.where(target_kong_id: @target_kong_id).where.not(id: replaced&.id).first
      return unless other

      raise InvalidChange, "#{@entity_type} #{other.entity_label} is already in this changeset (item #{other.position}) -- " \
        "remove that item first, then propose the change again"
    end

    # The admin path is never rendered into decK YAML (CLAUDE.md rule 3), so
    # neither it nor anything under it may enter a changeset.
    def refuse_admin_path_in_changeset!
      return unless @connection.admin_path?(@target_kong_id) || @connection.admin_path?(@parent_kong_id)

      raise InvalidChange, "admin-path entities never go into a changeset -- they are never rendered into decK YAML"
    end

    # A nested type (target) can't build any Admin API path without its
    # parent; a flat child (sni) needs it in the create body. An update/delete
    # may omit it -- the read-model's own record is the authority, and for a
    # flat child a missing one is fine (no path depends on it; the applier only
    # uses it to refresh the parent afterwards).
    def resolve_parent_kong_id
      return @parent_kong_id if @parent_kong_id.present?
      return nil unless @definition.requires_parent?

      found = @operation == "create" ? nil : cached_parent_kong_id
      return found if found.present?
      return nil if !@definition.nested? && @operation != "create"

      remedy = @operation == "create" ? "pick a #{@definition.parent_type}" : "sync this connection first, then retry"
      raise MissingParent, "can't tell which #{@definition.parent_type} this #{@entity_type} belongs to -- #{remedy}"
    end

    def cached_parent_kong_id
      KongEntity.active
        .where(kong_connection: @connection, entity_type: @entity_type, kong_id: @target_kong_id)
        .pick(:parent_kong_id)
    end

    # docs/DESIGN.md section 15 M5: Kong's own schema is the single source of
    # truth for what an upstream's `healthchecks` (or a target) may contain,
    # so a bad config is refused here, with Kong's per-field messages, instead
    # of surfacing at apply. Kong-managed fields are stripped (Kong owns
    # them), and a nested type's parent reference is added, since the schema
    # requires it and the form body doesn't carry it.
    def validate_against_kong_schema!(after)
      return unless @definition.schema_name && after
      # PR mode reads Kong through a read-only route, which answers any POST
      # with the router's 404; `deck gateway validate` covers PR mode in CI.
      return if @connection.apply_mode == "pr"

      body = after.except(*Kong::EntityTypes::KONG_MANAGED_FIELDS, *NOT_IN_KONG_SCHEMA.fetch(@entity_type, []))
      body = body.merge(@definition.parent_type => { "id" => @parent_kong_id }) if @definition.requires_parent? && @parent_kong_id.present?
      @client.post("/schemas/#{@definition.schema_name}/validate", body: body)
    rescue Kong::Client::UnexpectedResponse => e
      raise unless e.response&.status == 400

      raise SchemaViolation, "Kong rejected this #{@entity_type}: #{schema_violation_message(e.response)}"
    end

    # Flattens Kong's nested `fields` map into "healthchecks.active.http_path:
    # should start with: /" lines, falling back to its top-level message.
    def schema_violation_message(response)
      body = response.body
      body = JSON.parse(body) if body.is_a?(String)
      lines = flatten_field_errors(body["fields"]) if body.is_a?(Hash)
      lines.presence&.join("; ") || (body.is_a?(Hash) && body["message"]) || "invalid #{@entity_type}"
    rescue JSON::ParserError
      "invalid #{@entity_type}"
    end

    def flatten_field_errors(node, prefix = nil)
      case node
      when Hash
        node.flat_map { |key, value| flatten_field_errors(value, [ prefix, key ].compact.join(".")) }
      when Array
        [ "#{prefix}: #{node.join(', ')}" ]
      when nil
        []
      else
        [ "#{prefix}: #{node}" ]
      end
    end

    # A new plugin's proposed scope target, straight out of `attributes`
    # (string-keyed, matching Kong's own body shape -- `{"service" =>
    # {"id" => "..."}}`). nil for a global plugin, which can never be
    # admin-path since there's no target to check.
    def plugin_scope_kong_id
      %w[service route consumer].each do |type|
        id = @attributes.dig(type, "id")
        return id if id
      end
      nil
    end

    # Kong hands back credential secrets in plaintext (a key-auth `key` comes
    # over the wire as-is), so the live body is redacted before it is ever
    # stored on the plan or rendered on the review page -- change_plans is
    # not exempt from PRODUCT.md's "secrets are redacted before ever being
    # written" constraint. Everything downstream reads only non-secret keys
    # (`updated_at` for the optimistic lock, `id`/`tags` for the guardrails,
    # `name` for the audit event and decK YAML).
    def fetch_current
      response = @client.get(@definition.member_path(@target_kong_id, parent_kong_id: @parent_kong_id))
      body = response.body
      raw = body.is_a?(String) ? JSON.parse(body) : body
      Kong::Redactor.for_connection(@entity_type, raw, client: @client)[:data]
    end

    # prune_marked keeps the "[REDACTED]" placeholder that `before` now
    # carries from being merged into `after` and PATCHed back to Kong as the
    # literal credential. It is value-based, so a caller that supplies a
    # genuinely new secret still has it applied.
    def compute_after(before)
      case @operation
      when "create" then with_parent_reference(Kong::Redactor.prune_marked(@attributes))
      when "update" then Kong::Redactor.prune_marked(before.merge(@attributes))
      when "delete" then nil
      end
    end

    # An SNI's create body carries `certificate: {id}` -- the only way Kong
    # learns the parent, since the path is flat.
    def with_parent_reference(attributes)
      return attributes unless @definition.parent_in_body && @parent_kong_id.present?

      attributes.merge(@definition.parent_type => { "id" => @parent_kong_id })
    end

    def compute_diff(before, after)
      return { "operation" => "delete" } if @operation == "delete"
      return { "operation" => "create" } if @operation == "create"

      changed = {}
      after.each do |key, new_value|
        old_value = before[key]
        changed[key] = { "from" => old_value, "to" => new_value } unless old_value == new_value
      end
      changed
    end
  end
end
