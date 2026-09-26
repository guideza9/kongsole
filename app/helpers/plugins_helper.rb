module PluginsHelper
  # A plugin schema's `fields` is a flat array carrying the scope/meta
  # fields (`consumer`, `protocols`, `service`, `route`, `tags`...)
  # alongside one `config` entry -- only `config`'s own nested `fields` is
  # what the JSON editor's `config` key actually maps onto, so that's the
  # only part worth showing as reference.
  def plugin_config_fields(schema)
    config_field = Array(schema["fields"]).find { |f| f.key?("config") }
    config_field ? Array(config_field.dig("config", "fields")) : []
  end

  # R4.7: the config form (Kong::PluginSchemaForm fields). Needed first --
  # what is required or has no default, every secret among them -- and the
  # rest folded with its defaults showing.
  def plugin_fields_split(fields)
    fields.partition { |field| field.secret || field.default.nil? }
  end

  def plugin_field_id(field)
    "plugin-config-#{field.name}".tr("_", "-")
  end

  def plugin_field_error_id(field)
    "#{plugin_field_id(field)}-error"
  end

  def plugin_field_hint_id(field)
    "#{plugin_field_id(field)}-hint"
  end

  # What the form shows for a default: on/off for a switch, one per line for
  # a list, JSON for anything nested.
  def plugin_default_text(field)
    default = field.default
    case default
    when true then "on"
    when false then "off"
    when Array then default.empty? ? "none" : default.join(", ")
    when Hash then default.to_json
    else default.to_s
    end
  end

  # The value a control shows on re-render: what was typed, else nothing (a
  # blank control sends the default).
  def plugin_field_value(field, values)
    value = values.to_h[field.name]
    value.is_a?(Array) ? value.join("\n") : value
  end

  # A folded field that needs looking at: it has an error, or holds a value
  # other than its default.
  def plugin_field_attention?(field, values, errors)
    return true if errors[field.path].present?

    value = values.to_h[field.name]
    return false if value.blank?
    return value.to_s != (field.default ? "1" : "0") if field.kind == :boolean

    value.to_s != field.default.to_s
  end

  def plugin_switch_on?(field, values)
    value = values.to_h[field.name]
    value.nil? ? field.default == true : value.to_s == "1"
  end

  # The reference a secret field suggests: `{vault://env/rate-limiting-api-key}`,
  # which Kong reads from RATE_LIMITING_API_KEY on every node.
  def plugin_vault_example(plugin_name, field)
    var = "#{plugin_name}-#{field.name}".downcase.gsub(/[^a-z0-9]+/, "-")
    { example: "{vault://env/#{var}}", env_var: var.upcase.tr("-", "_"),
      deck: %(${{ env "DECK_#{var.upcase.tr('-', '_')}" }}) }
  end
end
