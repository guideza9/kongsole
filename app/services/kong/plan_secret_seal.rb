module Kong
  # R4.10: a direct-mode plugin plan keeps its secrets out of sight. The
  # plan's `after` and `diff` -- what the review page, the API/MCP, the audit
  # trail and the logs see -- carry "[REDACTED]"; the real values go into the
  # plan's encrypted `sealed_secrets`, which only Kong::ChangeApplier reads,
  # and which is cleared once the plan stops being pending.
  #
  # PR mode seals nothing: Kong::PluginSecretPolicy already refuses a plain
  # secret there, and the references it allows must reach the YAML.
  #
  # Sealing needs Active Record encryption keys. Where a machine has none
  # (see available?), the plan keeps the plain value as it did before R4.10
  # -- the owner's call (2026-09-26) -- and the caller logs that it did.
  module PlanSecretSeal
    def self.available?
      ActiveRecord::Encryption.config.primary_key.present? && ActiveRecord::Encryption.config.key_derivation_salt.present?
    rescue ActiveRecord::Encryption::Errors::Configuration
      false
    end

    def self.split(entity_type:, apply_mode:, after:, diff:, secret_paths:)
      unchanged = { after: after, diff: diff, sealed: nil }
      return unchanged unless entity_type.to_s == "plugin" && apply_mode == "direct"

      redacted_after = after && redact(after, secret_paths)
      redacted_diff = redact_diff(diff, secret_paths)
      return unchanged if redacted_after == after && redacted_diff == diff

      { after: redacted_after, diff: redacted_diff, sealed: { "after" => after, "diff" => diff } }
    end

    def self.redact(data, secret_paths)
      Kong::Redactor.call("plugin", data, secret_paths: secret_paths)[:data]
    end
    private_class_method :redact

    # A diff is shallow -- { key => { "from" => ..., "to" => ... } } -- so each
    # side is redacted as if it sat at that key of the plugin.
    def self.redact_diff(diff, secret_paths)
      return diff unless diff.is_a?(Hash)

      diff.to_h do |key, change|
        next [ key, change ] unless change.is_a?(Hash) && (change.key?("from") || change.key?("to"))

        [ key, change.to_h { |side, value| [ side, redact({ key => value }, secret_paths)[key] ] } ]
      end
    end
    private_class_method :redact_diff
  end
end
