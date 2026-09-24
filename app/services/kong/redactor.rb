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
      "certificate" => %w[key key_alt],
      "basicauth_credential" => %w[password],
      "keyauth_credential" => %w[key],
      "ca_certificate" => %w[key]
    }.freeze

    # Field names Kong's own schemas mark `encrypted: true` / `referenceable: true`
    # across the entities above -- redacted regardless of entity_type as a
    # second, defense-in-depth pass.
    SCHEMA_MARKED_FIELDS = %w[key password secret client_secret private_key tls_key].freeze

    # Plugin fail-closed rule (docs/DESIGN.md section 8): when a plugin's
    # schema could not be read, any config key whose name looks secret -- and
    # every `headers` map, where an Authorization header lives -- is redacted.
    FAIL_CLOSED_NAME = /(key|secret|password|passwd|token|credential|auth|private|cert)/i
    FAIL_CLOSED_MAPS = %w[headers].freeze

    # A `{vault://...}` value names a variable, it is not a secret.
    VAULT_REFERENCE = /\A\{vault:\/\/[^}]+\}\z/

    # `secret_paths` only matters for a plugin: an Array is the list of paths
    # its schema on this connection marks secret (Kong::PluginSecretFields);
    # nil means the schema could not be read, so the fail-closed heuristic
    # applies. `:unused` keeps every other entity_type's behavior unchanged.
    def self.call(entity_type, data, secret_paths: :unused)
      new(entity_type, data, secret_paths: secret_paths).call
    end

    # The one place a caller holding a live client redacts an entity: a
    # plugin is redacted against its own schema on that connection.
    def self.for_connection(entity_type, data, client:, schema_fields: Kong::PluginSecretFields.new)
      return call(entity_type, data) unless entity_type.to_s == "plugin"

      call(entity_type, data, secret_paths: schema_fields.fetch(client: client, plugin_name: data["name"]))
    end

    # Whether a field name carries a secret for this entity_type -- the one
    # place that question is answered, for redacting on the way in and
    # pruning on the way back out.
    def self.sensitive_key?(entity_type, key)
      key = key.to_s
      Array(SENSITIVE_FIELDS_BY_ENTITY[entity_type.to_s]).include?(key) || SCHEMA_MARKED_FIELDS.include?(key)
    end

    # M5b: on a certificate a `key` that is a vault/decK reference is a
    # pointer, not a secret, and operators need to see which variable it
    # names. Deliberately narrow -- certificate only, key/key_alt only -- so
    # a credential's `key` (or anything else) is never let through.
    REFERENCE_PASSTHROUGH_FIELDS = %w[key key_alt].freeze

    def self.reference_passthrough?(entity_type, key, value)
      entity_type.to_s == "certificate" &&
        REFERENCE_PASSTHROUGH_FIELDS.include?(key.to_s) &&
        Kong::CertificateKeyPolicy.reference?(value)
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
      deep_prune(data) do |key, _value|
        sensitive_key?(entity_type, key) && !policy_owned?(entity_type, key)
      end
    end

    # Certificate key/key_alt are judged by Kong::CertificateKeyPolicy, which
    # raises on anything but a reference, so they must reach it unpruned.
    def self.policy_owned?(entity_type, key)
      entity_type.to_s == "certificate" && REFERENCE_PASSTHROUGH_FIELDS.include?(key.to_s)
    end
    private_class_method :policy_owned?

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

    def initialize(entity_type, data, secret_paths: :unused)
      @entity_type = entity_type.to_s
      @data = data || {}
      @secret_paths = secret_paths
    end

    def call
      redacted = deep_redact(@data)
      redacted = redact_plugin(redacted) if @entity_type == "plugin" && @secret_paths != :unused
      { data: redacted, digest: digest(redacted) }
    end

    private

    def redact_plugin(data)
      return fail_closed(data) if @secret_paths.nil?

      @secret_paths.each_with_object(data) do |path, acc|
        parent = path.size == 1 ? acc : acc.dig(*path[0...-1])
        next unless parent.is_a?(Hash)

        value = parent[path.last]
        next if value.nil? || (value.is_a?(String) && VAULT_REFERENCE.match?(value))

        parent[path.last] = MARK
      end
    end

    def fail_closed(data)
      return data unless data["config"].is_a?(Hash)

      data.merge("config" => fail_closed_redact(data["config"]))
    end

    def fail_closed_redact(value)
      case value
      when Hash
        value.each_with_object({}) do |(key, v), acc|
          secret_name = FAIL_CLOSED_MAPS.include?(key.to_s) || FAIL_CLOSED_NAME.match?(key.to_s)
          acc[key] = secret_name && !v.nil? ? MARK : fail_closed_redact(v)
        end
      when Array
        value.map { |v| fail_closed_redact(v) }
      else
        value
      end
    end

    def deep_redact(value)
      case value
      when Hash
        value.each_with_object({}) do |(key, v), acc|
          acc[key] = redact?(key, v) ? MARK : deep_redact(v)
        end
      when Array
        value.map { |v| deep_redact(v) }
      else
        value
      end
    end

    def redact?(key, value)
      self.class.sensitive_key?(@entity_type, key) && !self.class.reference_passthrough?(@entity_type, key, value)
    end

    def digest(redacted)
      Digest::SHA256.hexdigest(redacted.to_json)
    end
  end
end
