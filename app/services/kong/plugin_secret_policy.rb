module Kong
  # What a plugin's secret fields may hold (R4) -- the fields its schema on
  # this connection marks encrypted/referenceable (Kong::PluginSecretFields).
  #
  # PR mode writes the plugin into the project's git repo, so a secret there
  # must be a reference, never the value:
  #   {vault://env/rate-limiting-api-key}       Kong reads the env var (CE: env vault only)
  #   ${{ env "DECK_RATE_LIMITING_API_KEY" }}   decK fills it in when CI syncs
  # Direct mode sends the value to Kong only; the read-model and the review
  # page redact it (T0.2), and the form suggests a vault reference anyway.
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
