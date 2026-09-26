module Kong
  # The plugins a connection's node has loaded (`GET /` →
  # plugins.available_on_server, read at login -- T0.5), each with what a
  # person needs to pick one: bundled with Kong or the team's own, a one-line
  # description, and the node's version and priority. A plugin the node has
  # not loaded is not listed: it cannot be configured there.
  #
  # Bundled = named in config/kong_bundled_plugins.yml; described by
  # hints.plugins.<name>.summary. Anything else is custom, described by
  # config/custom_plugins/<name>.yml when the team wrote one -- a nil summary
  # means it did not, and the page says so.
  class PluginCatalog
    Entry = Struct.new(:name, :custom, :summary, :docs_url, :version, :priority, :field_help, keyword_init: true)

    BUNDLED_LIST = Rails.root.join("config/kong_bundled_plugins.yml")
    # A metadata file is only opened for a name that cannot leave the directory.
    SAFE_NAME = /\A[a-z0-9][a-z0-9_-]*\z/

    def self.for(connection, metadata_dir: Rails.root.join("config/custom_plugins"))
      loaded = connection.plugins_available.fetch("available_on_server", {})
      loaded = {} unless loaded.is_a?(Hash)

      loaded.keys.sort.map do |name|
        node = loaded[name].is_a?(Hash) ? loaded[name] : {}
        details = bundled.include?(name) ? bundled_details(name) : custom_details(name, metadata_dir)
        Entry.new(name: name, version: node["version"], priority: node["priority"], **details)
      end
    end

    def self.bundled
      @bundled ||= Array(YAML.safe_load_file(BUNDLED_LIST)).to_set.freeze
    end

    def self.bundled_details(name)
      { custom: false, summary: I18n.t("hints.plugins.#{name}.summary", default: nil), docs_url: nil, field_help: {} }
    end
    private_class_method :bundled_details

    def self.custom_details(name, metadata_dir)
      meta = metadata(name, metadata_dir)
      help = meta["fields"].is_a?(Hash) ? meta["fields"].transform_keys(&:to_s).transform_values(&:to_s) : {}
      { custom: true, summary: meta["description"].presence&.to_s, docs_url: meta["docs_url"].presence&.to_s, field_help: help }
    end
    private_class_method :custom_details

    def self.metadata(name, metadata_dir)
      return {} unless SAFE_NAME.match?(name)

      path = Pathname(metadata_dir).join("#{name}.yml")
      return {} unless path.file?

      meta = YAML.safe_load_file(path)
      meta.is_a?(Hash) ? meta : {}
    rescue Psych::Exception
      {}
    end
    private_class_method :metadata
  end
end
