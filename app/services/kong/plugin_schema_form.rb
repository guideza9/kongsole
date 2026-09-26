module Kong
  # A plugin's schema on one connection, turned into the fields of its config
  # form (R4). Each top-level field of `config` becomes one control; anything
  # a single input cannot hold -- a record, a map, an array of records, at
  # any depth -- is edited as JSON at that top-level field, so no field drops
  # out of the form.
  #
  # `secret` is the schema's own mark (encrypted/referenceable, on the field
  # or its values -- Kong::PluginSecretFields): the form never prefills one.
  class PluginSchemaForm
    # `element_kind` is a :list's element type (:string, :number, :integer),
    # so the submitted lines go back to Kong typed. `nested_secrets` are the
    # secret paths inside a field edited as JSON (rate-limiting's
    # redis.password -> [["password"]]): never echoed back, always hinted.
    Field = Struct.new(:path, :name, :kind, :required, :default, :one_of, :secret, :description, :help, :element_kind,
      :nested_secrets, keyword_init: true)

    SCALARS = { "string" => :string, "number" => :number, "integer" => :integer, "boolean" => :boolean }.freeze
    LISTS = %w[array set].freeze

    def self.fields(schema, custom_help: {})
      config_fields(schema).filter_map do |field|
        name, spec = field.first
        next unless spec.is_a?(Hash)

        kind = kind(spec)
        Field.new(path: "config.#{name}", name: name, kind: kind, required: spec["required"] == true,
          default: default(spec), one_of: spec["one_of"], secret: secret?(name, spec),
          description: spec["description"], help: custom_help[name],
          element_kind: kind == :list ? SCALARS[spec.dig("elements", "type")] : nil,
          nested_secrets: nested_secrets(name, spec))
      end
    end

    def self.config_fields(schema)
      return [] unless schema.is_a?(Hash)

      config = Array(schema["fields"]).find { |field| field.is_a?(Hash) && field.key?("config") }
      config ? Array(config.dig("config", "fields")) : []
    end
    private_class_method :config_fields

    def self.kind(spec)
      return :enum if spec["one_of"].is_a?(Array) && SCALARS.key?(spec["type"])
      return SCALARS[spec["type"]] if SCALARS.key?(spec["type"])
      return :list if LISTS.include?(spec["type"]) && SCALARS.except("boolean").key?(spec.dig("elements", "type"))

      :json
    end
    private_class_method :kind

    # A record with no default of its own gets the defaults of its fields, as
    # Kong fills it (Kong 3.7.1's rate-limiting marks `redis` required with no
    # default) -- nil when none of them has one.
    def self.default(spec)
      return spec["default"] if spec.key?("default")
      return nil unless spec["type"] == "record"

      record_defaults(spec).presence
    end
    private_class_method :default

    def self.record_defaults(spec)
      Array(spec["fields"]).each_with_object({}) do |field, acc|
        name, sub = field.first
        next unless sub.is_a?(Hash)

        value = sub.key?("default") ? sub["default"] : (record_defaults(sub).presence if sub["type"] == "record")
        acc[name] = value unless value.nil?
      end
    end
    private_class_method :record_defaults

    def self.nested_secrets(name, spec)
      Kong::PluginSecretFields.paths("fields" => [ { name => spec } ]).select { |path| path.size > 1 }.map { |path| path.drop(1) }
    end
    private_class_method :nested_secrets

    def self.secret?(name, spec)
      Kong::PluginSecretFields.paths("fields" => [ { name => spec } ]).include?([ name ])
    end
    private_class_method :secret?
  end
end
