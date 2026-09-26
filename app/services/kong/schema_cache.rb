module Kong
  # Kong's schema for a plugin or an entity type on one connection, kept in
  # `kong_schemas` so the redactor (T0.2), the plugin form and the schema
  # mismatch warning (R4) share one copy. A copy is fresh for a day, and only
  # while the connection's Kong version is the one it was fetched from.
  # When Kong cannot be read, a stale copy is better than none; with no copy
  # at all the answer is nil and the caller decides (the redactor fails
  # closed).
  class SchemaCache
    MAX_AGE = 24.hours

    def self.fetch(connection:, client:, kind:, name:)
      cached = KongSchema.find_by(kong_connection: connection, kind: kind, name: name)
      return cached.body if fresh?(cached, connection)

      body = read(client, kind, name)
      store(connection, kind, name, body)
      body
    rescue Kong::Client::Error, JSON::ParserError
      cached&.body
    end

    def self.fresh?(cached, connection)
      cached && cached.kong_version == connection.kong_version && cached.fetched_at > MAX_AGE.ago
    end
    private_class_method :fresh?

    def self.read(client, kind, name)
      path = kind == "plugin" ? "/schemas/plugins/#{ERB::Util.url_encode(name)}" : "/schemas/#{ERB::Util.url_encode(name)}"
      body = client.get(path).body
      body = JSON.parse(body) if body.is_a?(String)
      raise JSON::ParserError, "schema is not an object" unless body.is_a?(Hash)

      body
    end
    private_class_method :read

    def self.store(connection, kind, name, body)
      KongSchema.upsert(
        { kong_connection_id: connection.id, kind: kind, name: name, kong_version: connection.kong_version,
          digest: KongSchema.digest_of(body), body: body, fetched_at: Time.current },
        unique_by: %i[kong_connection_id kind name]
      )
    end
    private_class_method :store
  end
end
