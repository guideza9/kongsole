module Kong
  # A plugin config form's params, turned back into Kong's plugin body (R4).
  # Each field is read by its kind (Kong::PluginSchemaForm); a value that
  # cannot be one is reported on its own field, as `"config.<name>" =>
  # [message]`, and never echoed -- it may be a secret.
  #
  # A field left blank sends the schema's default, or nothing when it has
  # none -- never "" or nil. A secret left blank sends nothing at all, so
  # Kong keeps (or does without) its value rather than getting the default.
  class PluginFormParams
    NUMBER = /\A-?\d+(\.\d+)?\z/
    INTEGER = /\A-?\d+\z/
    TRUE_VALUES = %w[1 true on yes].freeze
    FALSE_VALUES = %w[0 false off no].freeze
    OMIT = Object.new.freeze

    class Invalid < StandardError; end

    def self.call(fields:, params:)
      params = params.to_unsafe_h if params.respond_to?(:to_unsafe_h)
      new(fields, params.to_h.deep_stringify_keys).call
    end

    def initialize(fields, params)
      @fields = fields
      @params = params
      @errors = {}
    end

    def call
      config = @fields.each_with_object({}) do |field, acc|
        value = read(field, config_param(field.name))
        acc[field.name] = value unless value.equal?(OMIT)
      end
      [ plugin_attributes.merge("config" => config), @errors ]
    end

    private

    def config_param(name)
      config = @params["config"]
      config.is_a?(Hash) ? config[name] : nil
    end

    def read(field, raw)
      return blank_value(field) if blank?(raw)

      coerce(field, raw)
    rescue Invalid => e
      (@errors[field.path] ||= []) << e.message
      OMIT
    end

    def blank?(raw)
      raw.nil? || (raw.is_a?(String) && raw.strip.empty?)
    end

    def blank_value(field)
      return OMIT if field.secret
      return field.default unless field.default.nil?
      raise Invalid, "is required" if field.required

      OMIT
    end

    def coerce(field, raw)
      case field.kind
      when :number then number(raw)
      when :integer then integer(raw)
      when :boolean then boolean(raw)
      when :enum then enum(field, raw)
      when :list then list(field, raw)
      when :json then json(raw)
      else raw.to_s
      end
    end

    def number(raw)
      text = raw.to_s.strip
      raise Invalid, "must be a number, like 60 or 0.5" unless NUMBER.match?(text)

      text.include?(".") ? text.to_f : text.to_i
    end

    def integer(raw)
      text = raw.to_s.strip
      raise Invalid, "must be a whole number, like 60" unless INTEGER.match?(text)

      text.to_i
    end

    def boolean(raw)
      text = raw.to_s.strip.downcase
      return true if TRUE_VALUES.include?(text)
      return false if FALSE_VALUES.include?(text)

      raise Invalid, "must be on or off"
    end

    # The allowed value itself, so an integer enum goes back as an integer.
    def enum(field, raw)
      match = Array(field.one_of).find { |allowed| allowed.to_s == raw.to_s.strip }
      raise Invalid, "must be one of: #{Array(field.one_of).join(', ')}" if match.nil?

      match
    end

    def list(field, raw)
      lines = raw.is_a?(Array) ? raw.map(&:to_s) : raw.to_s.split(/\r?\n/)
      lines.map(&:strip).each_with_index.reject { |line, _| line.empty? }.map do |line, index|
        list_item(field, line)
      rescue Invalid => e
        raise Invalid, "line #{index + 1}: #{e.message}"
      end
    end

    def list_item(field, line)
      case field.element_kind
      when :integer then integer(line)
      when :number then number(line)
      else line
      end
    end

    def json(raw)
      JSON.parse(raw.to_s)
    rescue JSON::ParserError
      raise Invalid, "is not valid JSON -- check the brackets, quotes and commas"
    end

    def plugin_attributes
      attributes = {}
      attributes["enabled"] = TRUE_VALUES.include?(@params["enabled"].to_s.downcase) if @params.key?("enabled")
      tags = @params["tags"].to_s.split(/[\s,]+/).reject(&:empty?)
      attributes["tags"] = tags if tags.any?
      protocols = Array(@params["protocols"]).map(&:to_s).reject(&:empty?)
      attributes["protocols"] = protocols if protocols.any?
      attributes
    end
  end
end
