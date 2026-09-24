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
        marked = secret?(spec) || MEMBER_SPECS.any? { |member| spec[member].is_a?(Hash) && secret?(spec[member]) }
        own = marked ? [ path ] : []
        nested = spec["fields"] ? paths(spec, path) : []
        own + nested
      end
    end

    def self.secret?(spec)
      spec["encrypted"] || spec["referenceable"]
    end
    private_class_method :secret?

    def initialize
      @cache = {}
    end

    # nil when Kong would not say -- the caller must then fail closed.
    def fetch(client:, plugin_name:)
      return @cache[plugin_name] if @cache.key?(plugin_name)

      body = client.get("/schemas/plugins/#{ERB::Util.url_encode(plugin_name)}").body
      body = JSON.parse(body) if body.is_a?(String)
      @cache[plugin_name] = self.class.paths(body)
    rescue Kong::Client::Error, JSON::ParserError
      @cache[plugin_name] = nil
    end
  end
end
