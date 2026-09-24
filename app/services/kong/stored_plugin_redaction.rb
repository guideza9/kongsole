module Kong
  # One-off scrub of plugin secrets written before Kong::Redactor knew about
  # plugin schemas (T0.2). Stored rows have no live schema to consult, so the
  # fail-closed rules apply: secret-looking config keys and every `headers`
  # map. Touches plugin rows only, and counts only rows it actually changed.
  class StoredPluginRedaction
    def self.call
      new.call
    end

    def call
      { entities: scrub_entities, plans: scrub_plans, audit_events: scrub_audit_events }
    end

    private

    def scrub_entities
      count_changed(KongEntity.where(entity_type: "plugin")) do |entity|
        redacted = redact(entity.data)
        next false if redacted[:data] == entity.data

        entity.update_columns(data: redacted[:data], digest: redacted[:digest])
      end
    end

    def scrub_plans
      count_changed(ChangePlan.where(entity_type: "plugin")) do |plan|
        changes = {
          before: redact(plan.before)[:data],
          after: plan.after && redact(plan.after)[:data],
          diff: redact_diff(plan.diff)
        }.reject { |column, value| plan.public_send(column) == value }
        next false if changes.empty?

        plan.update_columns(changes)
      end
    end

    # AuditEvent is append-only at the model layer (readonly? after create).
    # Removing a secret it should never have held is the one sanctioned
    # rewrite, so it goes through a class-level update rather than save.
    def scrub_audit_events
      count_changed(AuditEvent.where(entity_type: "plugin")) do |event|
        diff = redact_diff(event.diff)
        next false if diff == event.diff

        AuditEvent.where(id: event.id).update_all(diff: diff)
      end
    end

    def count_changed(scope)
      scope.find_each.count { |record| yield(record) }
    end

    def redact(data)
      Kong::Redactor.call("plugin", data, secret_paths: nil)
    end

    # A diff is shallow -- { key => { "from" => ..., "to" => ... } } -- so
    # each side is redacted as if it sat at that key of a plugin.
    def redact_diff(diff)
      return diff unless diff.is_a?(Hash)

      diff.to_h do |key, change|
        next [ key, change ] unless change.is_a?(Hash) && (change.key?("from") || change.key?("to"))

        [ key, change.to_h { |side, value| [ side, redact({ key => value })[:data][key] ] } ]
      end
    end
  end
end
