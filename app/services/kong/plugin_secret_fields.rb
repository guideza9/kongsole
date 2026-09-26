module Kong
  # Which fields of a plugin are secret, read from that plugin's own schema on
  # the connection being synced (docs/DESIGN.md section 8). A custom plugin's
  # secrets are only knowable this way.
  class PluginSecretFields
    # A map or array counts when its values/elements are marked -- Kong marks
    # http-log's `headers` that way, and an Authorization header lives there.
    MEMBER_SPECS = %w[values elements].freeze

    def self.paths(schema, prefix = [])
      Array(schema["fields"]).flat_map do |field|
        name, spec = field.first
        next [] unless spec.is_a?(Hash)

        path = prefix + [ name ]
        marked = secret?(spec) || MEMBER_SPECS.any? { |member| member_secret?(spec[member]) }
        own = marked ? [ path ] : []
        nested = spec["fields"] ? paths(spec, path) : []
        own + nested
      end
    end

    def self.secret?(spec)
      spec["encrypted"] || spec["referenceable"]
    end
    private_class_method :secret?

    # A member spec is marked itself, or is a record with a secret anywhere
    # inside -- a path cannot index into an array or map, so the whole
    # collection is redacted.
    def self.member_secret?(member)
      member.is_a?(Hash) && (secret?(member) || (member["fields"] && paths(member).any?))
    end
    private_class_method :member_secret?

    def initialize
      @cache = {}
    end

    # nil when Kong would not say and no copy was ever cached -- the caller
    # must then fail closed. The schema comes through Kong::SchemaCache.
    def fetch(client:, plugin_name:)
      return @cache[plugin_name] if @cache.key?(plugin_name)

      schema = Kong::SchemaCache.fetch(connection: client.connection, client: client, kind: "plugin", name: plugin_name)
      @cache[plugin_name] = schema && self.class.paths(schema)
    end
  end
end
