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
    def initialize(connection:, client:, operation:, entity_type:, actor_username:, target_kong_id: nil,
                    parent_kong_id: nil, attributes: {}, actor_operator: nil, actor_kind: "human")
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
      @definition = Kong::EntityTypes.fetch(entity_type)
    end

    def call
      Kong::ChangeGuardrails.check_write_access!(connection: @connection)
      Kong::ChangeGuardrails.check_plugin_immutable!(
        connection: @connection, entity_type: @entity_type,
        target: @operation == "create" ? nil : { "id" => @target_kong_id },
        scope_kong_id: @operation == "create" ? plugin_scope_kong_id : nil
      )

      before = @operation == "create" ? {} : fetch_current

      if @actor_kind == "agent" && @operation == "delete"
        Kong::ChangeGuardrails.check_delete_confirmation!(
          connection: @connection, entity: before, confirmation_name: nil, actor_kind: "agent"
        )
      end

      after = compute_after(before)

      ChangePlan.create!(
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

    private

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
      response = @client.get("#{@definition.list_path}/#{@target_kong_id}")
      body = response.body
      raw = body.is_a?(String) ? JSON.parse(body) : body
      Kong::Redactor.call(@entity_type, raw)[:data]
    end

    # prune_marked keeps the "[REDACTED]" placeholder that `before` now
    # carries from being merged into `after` and PATCHed back to Kong as the
    # literal credential. It is value-based, so a caller that supplies a
    # genuinely new secret still has it applied.
    def compute_after(before)
      case @operation
      when "create" then Kong::Redactor.prune_marked(@attributes)
      when "update" then Kong::Redactor.prune_marked(before.merge(@attributes))
      when "delete" then nil
      end
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
