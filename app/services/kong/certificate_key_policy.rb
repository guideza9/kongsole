module Kong
  # The one authority on what a certificate's `key` / `key_alt` may hold --
  # docs/DESIGN.md section 8 and the M5b spec (section 3). A private key is
  # never accepted by this tool; it lives as an environment variable on
  # Kong's nodes and a certificate only *references* it.
  #
  #   {vault://env/cert-payments-key}    any apply mode. Kong reads the env
  #                                      var CERT_PAYMENTS_KEY at runtime.
  #   ${{ env "DECK_CERT_PAYMENTS_KEY" }} PR mode only. decK substitutes it
  #                                      when CI syncs; in direct mode nothing
  #                                      would, so the literal string would be
  #                                      written into Kong.
  #
  # Anything else is rejected loudly -- never silently dropped, which would
  # leave an operator believing a key was set when it was not.
  module CertificateKeyPolicy
    class Rejected < Kong::ChangePlanner::InvalidChange; end

    KEY_FIELDS = %w[key key_alt].freeze
    VAULT_REFERENCE = %r{\A\{vault://env/([a-z0-9][a-z0-9_-]*)\}\z}
    DECK_REFERENCE = /\A\$\{\{ env "(DECK_[A-Z0-9_]+)" \}\}\z/
    # A block ends at its END line, or -- for a truncated paste or a cut-off /
    # malformed END line -- at the end of input. A truncated block therefore
    # swallows the rest of the input; that is intended: half a key is still key
    # material, and the \z alternative keeps the scan linear.
    PRIVATE_KEY_BLOCK = /-----BEGIN [A-Z ]*PRIVATE KEY-----.*?(?:-----END [A-Z ]*PRIVATE KEY-----|\z)/m
    PRIVATE_KEY_MARKER = /-----BEGIN [A-Z ]*PRIVATE KEY-----/
    # The certificate family. Deliberately not every type: plugins and services
    # legitimately carry other PEMs (e.g. client certificates).
    DEEP_SCAN_TYPES = %w[certificate ca_certificate sni].freeze
    EXAMPLE = "{vault://env/cert-payments-key}".freeze

    def self.applies_to?(entity_type)
      entity_type.to_s == "certificate"
    end

    def self.vault_reference?(value)
      value.is_a?(String) && VAULT_REFERENCE.match?(value)
    end

    def self.deck_reference?(value)
      value.is_a?(String) && DECK_REFERENCE.match?(value)
    end

    def self.reference?(value)
      vault_reference?(value) || deck_reference?(value)
    end

    # The env var Kong (vault) or decK (placeholder) will read. Verified
    # against Kong 3.7.1: cert-payments-key -> CERT_PAYMENTS_KEY.
    def self.env_var_name(value)
      if (match = VAULT_REFERENCE.match(value.to_s)) && vault_reference?(value)
        match[1].upcase.tr("-", "_")
      elsif (match = DECK_REFERENCE.match(value.to_s)) && deck_reference?(value)
        match[1]
      end
    end

    def self.check!(attributes, entity_type:, apply_mode:, operation: nil)
      attributes ||= {}
      check_key_fields!(attributes, entity_type: entity_type, apply_mode: apply_mode, operation: operation)
      reject_nested_private_key!(attributes) if DEEP_SCAN_TYPES.include?(entity_type.to_s)
    end

    def self.check_key_fields!(attributes, entity_type:, apply_mode:, operation:)
      return unless applies_to?(entity_type)

      if operation == "create" && attributes["key"].blank?
        raise Rejected, "a certificate needs a key reference, e.g. #{EXAMPLE} (read from CERT_PAYMENTS_KEY on every Kong node)"
      end

      KEY_FIELDS.each do |field|
        next unless attributes.key?(field)

        value = attributes[field]
        next if value.nil? || value == Kong::Redactor::MARK
        next if vault_reference?(value)
        next if apply_mode == "pr" && deck_reference?(value)

        raise Rejected, rejection_message(field, value, apply_mode)
      end
    end

    # Env vars a plan will make Kong read, for the acknowledgement. Only a
    # plan that sets or changes a *vault* reference counts -- a tags edit or a
    # delete needs no confirmation, and a decK placeholder is CI's concern.
    def self.env_vars_for(change_plan)
      return [] unless applies_to?(change_plan.entity_type)

      fields =
        case change_plan.operation
        when "create" then KEY_FIELDS
        when "update" then KEY_FIELDS & change_plan.diff.keys
        else []
        end

      fields.filter_map do |field|
        value = change_plan.after[field]
        env_var_name(value) if vault_reference?(value)
      end.uniq
    end

    # Text that is about to be shown back to the operator (an error page that
    # re-renders what they typed) must never carry a private key they pasted.
    def self.scrub(text)
      text.to_s.gsub(PRIVATE_KEY_BLOCK, "[private key removed]")
    end

    # Walks the payload at any depth (Hashes and Arrays) and refuses a private
    # key wherever it hides -- e.g. {"foo" => {"key" => "<PEM>"}}, which the
    # top-level key/key_alt check never sees and which PR mode would persist
    # (Kong's schema check, that would reject the unknown field, is skipped
    # there). Names the JSON path only, never the value.
    def self.reject_nested_private_key!(node, path = nil)
      case node
      when Hash
        node.each do |field, value|
          # A Hash key can carry key material too, and it would land in the
          # path: render it as a placeholder rather than echoing it.
          segment = PRIVATE_KEY_MARKER.match?(field.to_s) ? "[key removed]" : field.to_s
          field_path = [ path, segment ].compact.join(".")
          reject!(field_path) if segment == "[key removed]"
          reject_nested_private_key!(value, field_path)
        end
      when Array
        node.each_with_index { |value, index| reject_nested_private_key!(value, "#{path}[#{index}]") }
      when String
        return unless PRIVATE_KEY_MARKER.match?(node)

        reject!(path)
      end
    end

    def self.reject!(path)
      raise Rejected, "#{path}: a private key can't be stored here, at any depth. Reference one instead: #{EXAMPLE}"
    end

    def self.rejection_message(field, value, apply_mode)
      hint = "Reference one instead: #{EXAMPLE} (read from CERT_PAYMENTS_KEY on every Kong node)"
      hint += ', or in PR mode ${{ env "DECK_CERT_PAYMENTS_KEY" }}' if apply_mode != "pr"
      if deck_reference?(value)
        return "#{field}: a decK placeholder only works in PR mode -- this connection applies directly, so nothing would fill it in. #{hint}"
      end

      "#{field}: a private key can't be set from here. #{hint}"
    end
    private_class_method :check_key_fields!, :reject_nested_private_key!, :reject!, :rejection_message
  end
end
