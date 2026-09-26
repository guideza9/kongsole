module Kong
  # What a plugin's secret fields may hold (R4) -- the fields its schema on
  # this connection marks encrypted/referenceable (Kong::PluginSecretFields).
  #
  # PR mode writes the plugin into the project's git repo, so a secret there
  # must be a reference, never the value:
  #   {vault://env/rate-limiting-api-key}       Kong reads the env var (CE: env vault only)
  #   ${{ env "DECK_RATE_LIMITING_API_KEY" }}   decK fills it in when CI syncs
  # Direct mode sends the value to Kong and takes it: the read-model redacts it
  # (T0.2), but the pending plan and its review page still hold it (the
  # deferred "plugin secrets in the write path" item), so the form suggests a
  # vault reference.
  #
  # A refusal names the field, never the value.
  module PluginSecretPolicy
    def self.check!(attributes, secret_paths:, apply_mode:)
      return unless apply_mode == "pr"

      if secret_paths.nil?
        raise Kong::ChangePlanner::InvalidChange,
          "Kong's schema for this plugin could not be read, so Kongsole cannot tell which fields are secret -- " \
          "nothing goes into git until it can. Check this machine reaches Kong, then try again."
      end

      plugin = attributes.to_h.deep_stringify_keys
      secret_paths.each do |path|
        next unless plain_value?(dig(plugin, path))

        raise Kong::ChangePlanner::InvalidChange, rejection_message(path, plugin["name"])
      end
    end

    # PR mode skips Kong's schema check, and a key the schema does not have
    # (a typo of api_key) is never checked as a secret: refuse it, at every
    # record depth. Named by path, never by value. A map's own keys are the
    # operator's, so a map (or a list) is not walked.
    def self.check_known_fields!(attributes, schema:)
      config_spec = Array(schema.to_h["fields"]).find { |field| field.is_a?(Hash) && field.key?("config") }&.dig("config")
      return unless config_spec

      unknown = unknown_path(attributes.to_h.deep_stringify_keys["config"], config_spec, [ "config" ])
      return unless unknown

      raise Kong::ChangePlanner::InvalidChange,
        "#{unknown.join('.')}: Kong's schema for #{attributes.to_h.deep_stringify_keys['name']} has no such field -- " \
        "check the name against the schema reference"
    end

    def self.unknown_path(value, spec, path)
      return nil unless value.is_a?(Hash) && spec.is_a?(Hash) && spec["type"] == "record"

      known = Array(spec["fields"]).to_h { |field| field.first }
      value.each do |key, child|
        return path + [ key ] unless known.key?(key)

        found = unknown_path(child, known[key], path + [ key ])
        return found if found
      end
      nil
    end
    private_class_method :unknown_path

    def self.dig(attributes, path)
      path.reduce(attributes) { |node, key| node.is_a?(Hash) ? node[key] : nil }
    end
    private_class_method :dig

    # A marked map or list (http-log's headers) holds secrets in every value.
    def self.plain_value?(value)
      case value
      when Hash then value.values.any? { plain_value?(_1) }
      when Array then value.any? { plain_value?(_1) }
      when String then !(value.empty? || value == Kong::Redactor::MARK || Kong::CertificateKeyPolicy.reference?(value))
      else false
      end
    end
    private_class_method :plain_value?

    def self.rejection_message(path, plugin_name)
      var = [ plugin_name.presence || "plugin", path.last ].join("-").downcase.gsub(/[^a-z0-9]+/, "-")
      env = var.upcase.tr("-", "_")
      "#{path.join('.')}: a secret can't go into git as plain text. Use a vault reference such as " \
        "{vault://env/#{var}} (Kong reads #{env} on every node), or a decK placeholder such as " \
        "${{ env \"DECK_#{env}\" }} (filled in when CI syncs)."
    end
    private_class_method :rejection_message
  end
end
