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
end
