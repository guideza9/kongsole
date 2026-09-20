module Kong
  # Strips secrets out of Kong entity payloads before they are ever written to
  # the read-model, returned from the API, or exported to decK YAML.
  #
  # Runs on every entity *before* it is persisted, per docs/DESIGN.md section 8:
  # certificate private keys, basic-auth/key-auth credential secrets, and any
  # field Kong's own plugin/entity schema marks `encrypted:` or `referenceable:`
  # are replaced with `[REDACTED]`. There is no flag to unredact -- once a
  # value is replaced, the plaintext never touches this process again.
  class Redactor
    MARK = "[REDACTED]"

    # Per-entity-type field names known to carry a secret, keyed by Kong's
    # Admin API entity_type. Kept explicit and small rather than "redact
    # everything called `key`" so an unrelated field named `key` on some other
    # entity is never silently dropped.
    SENSITIVE_FIELDS_BY_ENTITY = {
      "certificate" => %w[key],
      "basicauth_credential" => %w[password],
      "keyauth_credential" => %w[key],
      "ca_certificate" => %w[key]
    }.freeze

    # Field names Kong's own schemas mark `encrypted: true` / `referenceable: true`
    # across the entities above -- redacted regardless of entity_type as a
    # second, defense-in-depth pass.
    SCHEMA_MARKED_FIELDS = %w[key password secret client_secret private_key tls_key].freeze

    def self.call(entity_type, data)
      new(entity_type, data).call
    end

    # Whether a field name carries a secret for this entity_type -- the one
    # place that question is answered, for redacting on the way in and
    # pruning on the way back out.
    def self.sensitive_key?(entity_type, key)
      key = key.to_s
      Array(SENSITIVE_FIELDS_BY_ENTITY[entity_type.to_s]).include?(key) || SCHEMA_MARKED_FIELDS.include?(key)
    end

    # Drops every key still holding the redaction MARK, at any depth.
    #
    # Value-based on purpose: it removes only a placeholder inherited from an
    # already-redacted copy, never a real value a caller supplied. Kong's
    # PATCH is a partial update, so an omitted key keeps whatever Kong
    # already has -- which is exactly right for a field we never saw the
    # plaintext of. Without this, `before.merge(attributes)` in
    # Kong::ChangePlanner would write the literal string "[REDACTED]" into
    # Kong as the credential.
    def self.prune_marked(data)
      deep_prune(data) { |_key, value| value == MARK }
    end

    # Drops every secret-named key, whatever its value -- the web UI's
    # policy that credential secrets can never be set from a form (a typed
    # replacement is dropped just like an untouched "[REDACTED]" is).
    def self.prune_sensitive(entity_type, data)
      deep_prune(data) { |key, _value| sensitive_key?(entity_type, key) }
    end

    def self.deep_prune(value, &drop)
      case value
      when Hash
        value.each_with_object({}) do |(key, v), acc|
          next if drop.call(key, v)

          acc[key] = deep_prune(v, &drop)
        end
      when Array
        value.map { |v| deep_prune(v, &drop) }
      else
        value
      end
    end
    private_class_method :deep_prune

    def initialize(entity_type, data)
      @entity_type = entity_type.to_s
      @data = data || {}
    end

    def call
      redacted = deep_redact(@data)
      { data: redacted, digest: digest(redacted) }
    end

    private

    def deep_redact(value)
      case value
      when Hash
        value.each_with_object({}) do |(key, v), acc|
          acc[key] = redact_key?(key) ? MARK : deep_redact(v)
        end
      when Array
        value.map { |v| deep_redact(v) }
      else
        value
      end
    end

    def redact_key?(key)
      self.class.sensitive_key?(@entity_type, key)
    end

    def digest(redacted)
      Digest::SHA256.hexdigest(redacted.to_json)
    end
  end
end
