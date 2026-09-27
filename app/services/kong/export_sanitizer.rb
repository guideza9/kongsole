module Kong
  # Turns a `deck gateway dump` into a file safe to hand to a person or an agent
  # (R7, CLAUDE.md rule 2's one exception). Pure: it takes the dump's text and
  # never writes it anywhere.
  #
  #   - admin-path entities (tag `kong-admin-path`, or `is_admin_path` in the
  #     read-model) go, with everything nested under them and any plugin
  #     scoped to them (rule 3)
  #   - consumer credentials go (rule 4)
  #   - a certificate's private key and every plugin secret become a decK env
  #     placeholder, unless Kong already holds a vault reference there
  #   - `_info.select_tags` is the tags asked for, and the header says what the
  #     file is: a snapshot that owns everything under those tags
  #
  # A plugin whose schema this connection would not give (secret_paths_for
  # returns nil) is sanitized fail-closed on field names, like Kong::Redactor.
  class ExportSanitizer
    class Refused < StandardError; end

    Result = Struct.new(:yaml, :summary, :removed, :env_placeholders, :matched_nothing, keyword_init: true)

    ADMIN_PATH_TAG = "kong-admin-path".freeze
    TAG_FORMAT = /\A[A-Za-z0-9._~:-]{1,128}\z/

    # The dump's collections and the entity each holds, nested or top-level.
    COLLECTION_TYPES = {
      "services" => "service", "routes" => "route", "plugins" => "plugin", "consumers" => "consumer",
      "upstreams" => "upstream", "targets" => "target", "certificates" => "certificate", "snis" => "sni",
      "ca_certificates" => "ca_certificate", "vaults" => "vault", "consumer_groups" => "consumer_group"
    }.freeze
    # A collection named like this holds a consumer's secrets: dropped whole.
    CREDENTIAL_COLLECTION = /\A(?:[a-z0-9_]+_credentials|jwt_secrets)\z/
    # What a plugin, a service or a route can be scoped to by name.
    SCOPE_KEYS = { "service" => "service", "route" => "route", "consumer" => "consumer" }.freeze
    CERTIFICATE_KEY_FIELDS = %w[key key_alt].freeze

    def self.call(text, connection:, select_tags:, secret_paths_for:)
      new(connection: connection, select_tags: select_tags, secret_paths_for: secret_paths_for).call(text)
    end

    def self.validate_tags!(select_tags)
      tags = select_tags
      raise Refused, "select_tags must be a list of tags" unless tags.is_a?(Array) && tags.all?(String)
      raise Refused, "an export needs at least one select tag" if tags.empty?
      raise Refused, "#{ADMIN_PATH_TAG} can't be exported -- it is the way into the Admin API" if tags.include?(ADMIN_PATH_TAG)

      bad = tags.reject { |tag| TAG_FORMAT.match?(tag) }
      raise Refused, "these aren't tags Kong accepts: #{bad.map(&:inspect).join(', ')}" if bad.any?

      tags
    end

    def initialize(connection:, select_tags:, secret_paths_for:)
      @connection = connection
      @select_tags = self.class.validate_tags!(select_tags)
      @secret_paths_for = secret_paths_for
      @removed = []
      @placeholders = []
      @summary = Hash.new(0)
    end

    def call(text)
      doc = Kong::DeckDocument.parse(text, select_tags: @select_tags)
      @tagged_admin_names = collect_tagged_admin(doc)
      body = sanitize_document(doc)
      yaml = header + Kong::DeckDocument.serialize(body)
      Result.new(yaml: yaml, summary: @summary.sort.to_h, removed: @removed, env_placeholders: @placeholders,
        matched_nothing: @summary.empty?)
    end

    private

    # Every top-level collection, then a last sweep for a private key anywhere.
    def sanitize_document(doc)
      doc.each_with_object({}) do |(key, value), out|
        if %w[_format_version _info].include?(key)
          out[key] = value
        elsif CREDENTIAL_COLLECTION.match?(key)
          record_credentials(key, value, owner: nil)
        elsif COLLECTION_TYPES.key?(key) && value.is_a?(Array)
          out[key] = sanitize_collection(key, value, parent_admin: false)
        else
          out[key] = scrub_private_keys(value, [ key ])
        end
      end
    end

    def sanitize_collection(key, items, parent_admin:)
      type = COLLECTION_TYPES.fetch(key)
      items.filter_map do |item|
        next scrub_private_keys(item, [ type ]) unless item.is_a?(Hash)

        if parent_admin || admin_path?(type, item)
          @removed << { type: type, name: display_name(type, item), reason: :admin_path }
          next
        end

        @summary[type] += 1
        sanitize_entity(type, item)
      end
    end

    def sanitize_entity(type, item)
      name = display_name(type, item)
      item.each_with_object({}) do |(key, value), out|
        if CREDENTIAL_COLLECTION.match?(key)
          record_credentials(key, value, owner: name)
        elsif COLLECTION_TYPES.key?(key) && value.is_a?(Array)
          out[key] = sanitize_collection(key, value, parent_admin: false)
        elsif type == "certificate" && CERTIFICATE_KEY_FIELDS.include?(key)
          out[key] = certificate_key(item, key, value)
        elsif type == "plugin" && key == "config"
          out[key] = plugin_config(item["name"].to_s, value)
        elsif type == "vault" && key == "config"
          out[key] = fail_closed(value, [ "VAULT", item["prefix"] || item["name"] ], "vault #{name}", "config")
        else
          out[key] = scrub_private_keys(value, [ type, name, key ])
        end
      end
    end

    # --- admin path ---------------------------------------------------------

    def admin_path?(type, item)
      Array(item["tags"]).include?(ADMIN_PATH_TAG) ||
        admin_names.include?([ type, entity_name(item) ]) ||
        SCOPE_KEYS.any? { |field, scope_type| admin_names.include?([ scope_type, reference_name(item[field]) ]) }
    end

    # The read-model's own view, which knows admin-path entities the tag misses
    # (a consumer the admin route's ACL lets in). Service and route scopes found
    # by tag count too, so a top-level plugin naming one is dropped.
    def admin_names
      @admin_names ||= begin
        names = KongEntity.where(kong_connection: @connection, is_admin_path: true).pluck(:entity_type, :name).to_set
        names | tagged_admin_names
      end
    end

    def tagged_admin_names
      @tagged_admin_names || Set.new
    end

    # A first pass over the whole dump: top-level plugins come before
    # `services` in the file, so a service's tag must be known before them.
    # Whatever sits under an admin-path entity is admin path too.
    def collect_tagged_admin(node, names = Set.new, inherited: false)
      return names unless node.is_a?(Hash)

      node.each do |key, value|
        type = COLLECTION_TYPES[key]
        next unless type && value.is_a?(Array)

        value.grep(Hash).each do |item|
          admin = inherited || Array(item["tags"]).include?(ADMIN_PATH_TAG)
          names << [ type, entity_name(item) ] if admin
          collect_tagged_admin(item, names, inherited: admin)
        end
      end
      names
    end

    def reference_name(ref)
      case ref
      when String then ref
      when Hash then ref["name"] || ref["username"] || ref["id"]
      end
    end

    # --- credentials --------------------------------------------------------

    def record_credentials(key, value, owner:)
      type = key.delete_suffix("s")
      Array(value).each do |credential|
        @removed << { type: type, name: owner || credential_owner(credential), reason: :credential }
      end
    end

    def credential_owner(credential)
      credential.is_a?(Hash) ? reference_name(credential["consumer"]).to_s : ""
    end

    # --- certificates -------------------------------------------------------

    def certificate_key(item, field, value)
      return value if value.nil? || Kong::CertificateKeyPolicy.reference?(value)

      name = display_name("certificate", item)
      @removed << { type: "certificate", name: name, reason: :private_key } if field == "key"
      placeholder([ "CERT", name, field ])
    end

    # --- plugin secrets -----------------------------------------------------

    def plugin_config(plugin_name, config)
      return config unless config.is_a?(Hash)

      paths = @secret_paths_for.call(plugin_name)
      return fail_closed(config, [ "PLUGIN", plugin_name ], plugin_name, "config") if paths.nil?

      config = config.deep_dup
      paths.each do |path|
        field_path = path.first == "config" ? path.drop(1) : path
        next if field_path.empty?

        parent = field_path.size == 1 ? config : config.dig(*field_path[0...-1])
        next unless parent.is_a?(Hash) && parent.key?(field_path.last)

        parent[field_path.last] = replace_secret(parent[field_path.last], [ "PLUGIN", plugin_name, *field_path ],
          "#{plugin_name}: config.#{field_path.join('.')}")
      end
      scrub_private_keys(config, [ "PLUGIN", plugin_name ])
    end

    # Kong::Redactor's rule: a secret-looking name, or any `headers` map.
    def fail_closed(value, parts, label, path_label)
      return value unless value.is_a?(Hash)

      value.each_with_object({}) do |(key, v), out|
        secret = Kong::Redactor::FAIL_CLOSED_MAPS.include?(key.to_s) || Kong::Redactor::FAIL_CLOSED_NAME.match?(key.to_s)
        out[key] =
          if secret
            replace_secret(v, [ *parts, key ], "#{label}: #{path_label}.#{key}")
          elsif v.is_a?(Hash)
            fail_closed(v, [ *parts, key ], label, "#{path_label}.#{key}")
          else
            scrub_private_keys(v, [ *parts, key ])
          end
      end
    end

    # A string becomes a placeholder; a map or list keeps its shape with one
    # placeholder per string inside. A boolean or number is not a secret
    # (`hide_credentials: true`), and a vault reference already names one.
    def replace_secret(value, parts, label)
      case value
      when Hash
        value.to_h { |key, v| [ key, replace_secret(v, [ *parts, key ], label) ] }
      when Array
        value.each_with_index.map { |v, i| replace_secret(v, [ *parts, (i + 1).to_s ], label) }
      when String
        return value if Kong::Redactor::VAULT_REFERENCE.match?(value) || Kong::CertificateKeyPolicy.reference?(value)

        record_secret(label)
        placeholder(parts)
      else
        value
      end
    end

    def record_secret(label)
      entry = { type: "plugin", name: label, reason: :plugin_secret }
      @removed << entry unless @removed.include?(entry)
    end

    # --- last sweep ---------------------------------------------------------

    # Whatever the rules above missed, a PEM private key never leaves.
    def scrub_private_keys(value, parts)
      case value
      when Hash then value.to_h { |key, v| [ key, scrub_private_keys(v, [ *parts, key ]) ] }
      when Array then value.each_with_index.map { |v, i| scrub_private_keys(v, [ *parts, (i + 1).to_s ]) }
      when String
        return value unless Kong::CertificateKeyPolicy::PRIVATE_KEY_BLOCK.match?(value)

        @removed << { type: parts.first.to_s.downcase, name: parts.drop(1).join("."), reason: :private_key }
        placeholder([ *parts, "KEY" ])
      else value
      end
    end

    # --- names --------------------------------------------------------------

    # DECK_ + the parts, upper-cased, anything else as `_`. A name already
    # handed out gets _2, _3 ... in document order, so two plugins of one kind
    # never share a variable (and the same dump always numbers them alike).
    def placeholder(parts)
      base = "DECK_#{parts.map(&:to_s).join('_').upcase.gsub(/[^A-Z0-9]+/, '_').gsub(/\A_+|_+\z/, '')}"
      name = base
      suffix = 1
      name = "#{base}_#{suffix += 1}" while @placeholders.include?(name)
      @placeholders << name
      %(${{ env "#{name}" }})
    end

    def entity_name(item)
      item["name"] || item["username"] || item["custom_id"] || item["target"] || item["prefix"] || item["id"]
    end

    def display_name(type, item)
      if type == "certificate"
        sni = Array(item["snis"]).first
        sni_name = sni.is_a?(Hash) ? sni["name"] : sni
        return (sni_name || item["id"]).to_s
      end

      entity_name(item).to_s
    end

    def header
      <<~HEADER
        # Exported by Kongsole from #{@connection.name} with select_tags [#{@select_tags.join(', ')}].
        # A snapshot of Kong, not a source of truth. It holds EVERYTHING Kong tags with
        # these select_tags, so `deck gateway sync` against another env deletes whatever
        # that env has under these tags and this file lacks.
        # Secrets are replaced by decK env placeholders (DECK_* variables): set them before syncing.
        # A PR-mode env must receive this through a PR to its project repo, never a manual sync.
      HEADER
    end
  end
end
