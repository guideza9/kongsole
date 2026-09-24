module Kong
  # An entity type's schema as the connection's own Kong reports it
  # (GET /schemas/<name>), flattened into reference rows for the JSON-editor
  # forms (R3). nil when Kong cannot be read -- the page then shows hints alone.
  class EntitySchema
    def self.fields(client:, entity_type:)
      name = Kong::EntityTypes.fetch(entity_type).schema_name || "#{entity_type}s"
      body = client.get("/schemas/#{name}").body
      body = JSON.parse(body) if body.is_a?(String)
      rows(body).reject { |row| Kong::EntityTypes::KONG_MANAGED_FIELDS.include?(row[:name]) }
    rescue Kong::Client::Error, JSON::ParserError
      nil
    end

    def self.rows(schema)
      Array(schema.is_a?(Hash) ? schema["fields"] : nil).filter_map do |field|
        name, spec = field.first
        next unless spec.is_a?(Hash)

        { name: name, type: spec["type"], required: spec["required"] == true, default: spec["default"],
          one_of: spec["one_of"], nested: spec["fields"] ? rows(spec) : [] }
      end
    end
    private_class_method :rows
  end
end
