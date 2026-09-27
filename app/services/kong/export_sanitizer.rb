module Kong
  # Turns a `deck gateway dump` into a file safe to hand to a person or an agent
  # (R7, CLAUDE.md rule 2's one exception). Pure: it takes the dump's text and
  # never writes it anywhere.
  #
  #   - admin-path entities (tag `kong-admin-path`, or `is_admin_path` in the
  #     read-model) go, with everything nested under them and any plugin
  #     scoped to them (rule 3)
  #   - consumer credentials go (rule 4)
  #   - a certificate's private key, a key's private JWK/PEM and every plugin
  #     secret become a decK env placeholder, unless Kong already holds a vault
  #     reference there
  #   - `_info.select_tags` is the tags asked for, and the header says what the
  #     file is: a snapshot that owns everything under those tags, and what it
  #     left out that a sync would therefore delete
  #
  # A plugin whose schema this connection would not give (secret_paths_for
  # returns nil), a vault's config and a collection this class does not know
  # are sanitized fail-closed on field names, like Kong::Redactor.
  class ExportSanitizer
    class Refused < StandardError; end

    Result = Struct.new(:yaml, :summary, :removed, :env_placeholders, :matched_nothing, keyword_init: true)

    ADMIN_PATH_TAG = "kong-admin-path".freeze
    TAG_FORMAT = /\A[A-Za-z0-9._~:-]{1,128}\z/

    # The dump's collections and the entity each holds, nested or top-level.
    COLLECTION_TYPES = {
      "services" => "service", "routes" => "route", "plugins" => "plugin", "consumers" => "consumer",
      "upstreams" => "upstream", "targets" => "target", "certificates" => "certificate", "snis" => "sni",
      "ca_certificates" => "ca_certificate", "vaults" => "vault", "consumer_groups" => "consumer_group",
      "keys" => "key", "key_sets" => "key_set"
    }.freeze
    # A collection named like this holds a consumer's secrets: dropped whole.
    CREDENTIAL_COLLECTION = /\A(?:[a-z0-9_]+_credentials|jwt_secrets)\z/
    # What a plugin, a service or a route can be scoped to by name.
    SCOPE_KEYS = { "service" => "service", "route" => "route", "consumer" => "consumer" }.freeze
    # Kinds whose name Kong keeps unique, so a name can say "this is the admin
    # path". A plugin's read-model name is its kind ("basic-auth"): matching it
    # by name would drop every basic-auth in the file (final review C2).
    NAME_MATCH_TYPES = %w[service route consumer upstream].freeze
    # The entities a plugin nested under them is scoped to, for its variable names.
    PLUGIN_SCOPES = %w[service route consumer consumer_group].freeze
    CERTIFICATE_KEY_FIELDS = %w[key key_alt].freeze
    LEFT_OUT = %i[admin_path credential].freeze

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
      @placeholder_names = Set.new
      @summary = Hash.new(0)
      @seen = 0
    end

    def call(text)
      doc = Kong::DeckDocument.parse(text, select_tags: @select_tags)
      @tagged_admin_names = Set.new
      @plugin_counts = Hash.new(0)
      survey(doc)
      body = sanitize_document(doc)
      yaml = header + Kong::DeckDocument.serialize(body)
      Result.new(yaml: yaml, summary: @summary.sort.to_h, removed: @removed, env_placeholders: @placeholders,
        matched_nothing: @seen.zero?)
    end

    private

    # Every top-level collection; anything this class does not know is
    # sanitized fail-closed, never passed through.
    def sanitize_document(doc)
      doc.each_with_object({}) do |(key, value), out|
        if %w[_format_version _info].include?(key)
          out[key] = value
        elsif CREDENTIAL_COLLECTION.match?(key)
          record_credentials(key, value, owner: nil)
        elsif COLLECTION_TYPES.key?(key) && value.is_a?(Array)
          out[key] = sanitize_collection(key, value, scope: nil)
        elsif value.is_a?(Array)
          out[key] = unknown_collection(key, value)
        else
          out[key] = scrub_private_keys(value, [ key ])
        end
      end
    end

    def sanitize_collection(key, items, scope:)
      type = COLLECTION_TYPES.fetch(key)
      items.filter_map do |item|
        next scrub_private_keys(item, [ type ]) unless item.is_a?(Hash)

        @seen += 1
        if admin_path?(type, item)
          @removed << { type: type, name: display_name(type, item), reason: :admin_path }
          next
        end

        @summary[type] += 1
        sanitize_entity(type, item, scope)
      end
    end

    def sanitize_entity(type, item, scope)
      name = display_name(type, item)
      child_scope = PLUGIN_SCOPES.include?(type) ? [ type, name ] : scope
      item.each_with_object({}) do |(key, value), out|
        out[key] = sanitize_field(type, item, name, key, value, child_scope, scope)
      end.compact
    end

    # `nil` drops the field (a credential collection).
    def sanitize_field(type, item, name, key, value, child_scope, scope)
      if CREDENTIAL_COLLECTION.match?(key)
        record_credentials(key, value, owner: name)
        nil
      elsif COLLECTION_TYPES.key?(key) && value.is_a?(Array)
        sanitize_collection(key, value, scope: child_scope)
      elsif type == "certificate" && CERTIFICATE_KEY_FIELDS.include?(key)
        certificate_key(item, key, value)
      elsif type == "plugin" && key == "config"
        plugin_config(item, value, scope)
      elsif type == "vault" && key == "config"
        fail_closed(value, [ "VAULT", item["prefix"] || item["name"] ], "vault", "#{name}: config")
      elsif type == "key" && %w[jwk pem].include?(key)
        private_key_material(name, key, value)
      elsif type == "upstream" && key == "healthchecks"
        header_maps(value, [ "UPSTREAM", name, key ], "upstream", "#{name}: #{key}")
      else
        scrub_private_keys(value, [ type, name, key ])
      end
    end

    # --- admin path ---------------------------------------------------------

    def admin_path?(type, item)
      return true if Array(item["tags"]).include?(ADMIN_PATH_TAG)
      return true if NAME_MATCH_TYPES.include?(type) && admin_names.include?([ type, entity_name(item) ])

      SCOPE_KEYS.any? { |field, scope_type| admin_names.include?([ scope_type, reference_name(item[field]) ]) }
    end

    # The read-model's own view, which knows admin-path entities the tag misses
    # (a consumer the admin route's ACL lets in), plus what the dump tags.
    def admin_names
      @admin_names ||= KongEntity.where(kong_connection: @connection, is_admin_path: true, entity_type: NAME_MATCH_TYPES)
        .pluck(:entity_type, :name).to_set | @tagged_admin_names
    end

    # A first pass over the whole dump, before anything is written: top-level
    # plugins come before `services` in the file, so a service's admin-path tag
    # must be known first (whatever sits under it is admin path too), and a
    # plugin kind that appears more than once gets scoped variable names.
    def survey(node, inherited: false)
      return unless node.is_a?(Hash)

      node.each do |key, value|
        type = COLLECTION_TYPES[key]
        next unless type && value.is_a?(Array)

        value.grep(Hash).each do |item|
          admin = inherited || Array(item["tags"]).include?(ADMIN_PATH_TAG)
          @tagged_admin_names << [ type, entity_name(item) ] if admin && NAME_MATCH_TYPES.include?(type)
          @plugin_counts[item["name"].to_s] += 1 if type == "plugin"
          survey(item, inherited: admin)
        end
      end
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

    # --- keys ---------------------------------------------------------------

    def certificate_key(item, field, value)
      return value if value.nil? || Kong::CertificateKeyPolicy.reference?(value)

      name = display_name("certificate", item)
      @removed << { type: "certificate", name: field == "key" ? name : "#{name} (#{field})", reason: :private_key }
      placeholder([ "CERT", name, field ])
    end

    # A key entity's JWK holds its private part; its PEM, a private_key.
    def private_key_material(name, field, value)
      parts = [ "KEY", name, field ]
      if field == "jwk"
        record(type: "key", name: "#{name}: jwk", reason: :private_key) if value.is_a?(String) && !Kong::CertificateKeyPolicy.reference?(value)
        return replace_secret(value, parts, nil)
      end
      return value unless value.is_a?(Hash) && value.key?("private_key")

      record(type: "key", name: "#{name}: pem.private_key", reason: :private_key)
      value.merge("private_key" => replace_secret(value["private_key"], [ *parts, "private_key" ], nil))
    end

    # --- plugin secrets -----------------------------------------------------

    def plugin_config(plugin, config, scope)
      return config unless config.is_a?(Hash)

      plugin_name = plugin["name"].to_s
      scope = plugin_scope(plugin, scope)
      shared = @plugin_counts[plugin_name] > 1
      parts = shared ? [ "PLUGIN", *scope, plugin_name ] : [ "PLUGIN", plugin_name ]
      label = shared ? "#{plugin_name} (#{scope.join(' ')})" : plugin_name

      paths = @secret_paths_for.call(plugin_name)
      return fail_closed(config, parts, "plugin", "#{label}: config") if paths.nil?

      config = config.deep_dup
      paths.each do |path|
        field_path = path.first == "config" ? path.drop(1) : path
        next if field_path.empty?

        parent = field_path.size == 1 ? config : config.dig(*field_path[0...-1])
        next unless parent.is_a?(Hash) && parent.key?(field_path.last)

        parent[field_path.last] = replace_secret(parent[field_path.last], [ *parts, *field_path ],
          { type: "plugin", name: "#{label}: config.#{field_path.join('.')}" })
      end
      schema_marked(config, parts, "#{label}: config")
    end

    # Where the plugin runs, for its variable names: the entity it is nested
    # under, the one a top-level plugin names, or global.
    def plugin_scope(plugin, scope)
      return scope.map(&:to_s) if scope

      field, = SCOPE_KEYS.find { |key, _| plugin[key].present? }
      field ? [ field, reference_name(plugin[field]).to_s ] : [ "global" ]
    end

    # Kong::Redactor's second pass: field names Kong's schemas mark secret on
    # its own entities, at any depth, even where this plugin's schema did not.
    def schema_marked(value, parts, path_label)
      case value
      when Hash
        value.to_h do |key, v|
          next [ key, replace_secret(v, [ *parts, key ], { type: "plugin", name: "#{path_label}.#{key}" }) ] if Kong::Redactor::SCHEMA_MARKED_FIELDS.include?(key.to_s)

          [ key, schema_marked(v, [ *parts, key ], "#{path_label}.#{key}") ]
        end
      when Array then value.each_with_index.map { |v, i| schema_marked(v, [ *parts, (i + 1).to_s ], "#{path_label}[#{i}]") }
      else scrub_private_keys(value, parts)
      end
    end

    # Kong::Redactor's fail-closed rule -- a secret-looking name, or any
    # `headers` map -- at any depth, lists of records included.
    def fail_closed(value, parts, type, path_label)
      case value
      when Hash
        value.to_h do |key, v|
          secret = Kong::Redactor::FAIL_CLOSED_MAPS.include?(key.to_s) || Kong::Redactor::FAIL_CLOSED_NAME.match?(key.to_s)
          next [ key, replace_secret(v, [ *parts, key ], { type: type, name: "#{path_label}.#{key}" }) ] if secret

          [ key, fail_closed(v, [ *parts, key ], type, "#{path_label}.#{key}") ]
        end
      when Array
        value.each_with_index.map { |v, i| fail_closed(v, [ *parts, (i + 1).to_s ], type, "#{path_label}[#{i}]") }
      else
        scrub_private_keys(value, parts)
      end
    end

    # Only the `headers` maps inside (an upstream health check sends them, an
    # Authorization among them); a route's `headers` are match rules and stay.
    def header_maps(value, parts, type, path_label)
      case value
      when Hash
        value.to_h do |key, v|
          next [ key, replace_secret(v, [ *parts, key ], { type: type, name: "#{path_label}.#{key}" }) ] if key.to_s == "headers"

          [ key, header_maps(v, [ *parts, key ], type, "#{path_label}.#{key}") ]
        end
      else
        scrub_private_keys(value, parts)
      end
    end

    # A top-level collection decK dumped and this class does not know: counted,
    # and every entry sanitized fail-closed.
    def unknown_collection(key, items)
      type = key.singularize
      items.map do |item|
        next scrub_private_keys(item, [ key ]) unless item.is_a?(Hash)

        @seen += 1
        @summary[type] += 1
        name = entity_name(item).to_s
        fail_closed(item, [ key, name ], type, "#{type} #{name}")
      end
    end

    # A string becomes a placeholder; a map or list keeps its shape with one
    # placeholder per string inside. A boolean or number is not a secret
    # (`hide_credentials: true`), and a reference already names one.
    def replace_secret(value, parts, entry)
      case value
      when Hash
        value.to_h { |key, v| [ key, replace_secret(v, [ *parts, key ], entry) ] }
      when Array
        value.each_with_index.map { |v, i| replace_secret(v, [ *parts, (i + 1).to_s ], entry) }
      when String
        return value if Kong::Redactor::VAULT_REFERENCE.match?(value) || Kong::CertificateKeyPolicy.reference?(value)

        record(**entry, reason: entry[:type] == "plugin" ? :plugin_secret : :secret) if entry
        placeholder(parts)
      else
        value
      end
    end

    # One row per field, however many strings it held (a headers map).
    def record(type:, name:, reason:)
      entry = { type: type, name: name, reason: reason }
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

    # DECK_ + the parts, upper-cased, anything else as `_`. Plugin names carry
    # their scope when one kind appears more than once, so a name only moves
    # when what it belongs to does; `_2` is the last resort for a true clash.
    def placeholder(parts)
      base = "DECK_#{parts.map(&:to_s).join('_').upcase.gsub(/[^A-Z0-9]+/, '_').gsub(/\A_+|_+\z/, '')}"
      name = base
      suffix = 1
      name = "#{base}_#{suffix += 1}" while @placeholder_names.include?(name)
      @placeholder_names << name
      @placeholders << name
      %(${{ env "#{name}" }})
    end

    def entity_name(item)
      item["name"] || item["username"] || item["custom_id"] || item["target"] || item["prefix"] || item["kid"] || item["id"]
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
      lines = [
        "# Exported by Kongsole from #{@connection.name} with select_tags [#{@select_tags.join(', ')}].",
        "# A snapshot of Kong, not a source of truth. It holds EVERYTHING Kong tags with",
        "# these select_tags, so `deck gateway sync` against another env deletes whatever",
        "# that env has under these tags and this file lacks."
      ]
      left_out = @removed.count { |row| LEFT_OUT.include?(row[:reason]) }
      if left_out.positive?
        lines << "# WARNING: #{left_out} #{left_out == 1 ? 'entity' : 'entities'} under these select_tags are left out of this file"
        lines << "# (Kongsole's admin route, consumer credentials): a sync deletes them wherever they exist."
      end
      lines << "# Secrets are replaced by decK env placeholders (DECK_* variables): set them before syncing."
      lines << "# A PR-mode env must receive this through a PR to its project repo, never a manual sync."
      "#{lines.join("\n")}\n"
    end
  end
end
