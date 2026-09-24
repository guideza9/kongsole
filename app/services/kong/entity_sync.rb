module Kong
  # Pulls one entity type from a connection's Kong Admin API into the
  # kong_entities read-model (docs/DESIGN.md section 7). Paths come from
  # Kong::EntityTypes; identity (name/logical_key/parent) follows section 7's
  # "กฎ identity ของ entity" table per entity_type.
  class EntitySync
    PAGE_SIZE = 100

    # services/consumers first: routes and credentials need their parent's
    # name already synced to build a readable logical_key (see
    # parent_name_map below). plugin goes last -- its Scope column (rendered
    # later, not at sync time) looks up whichever of service/route/consumer
    # it's attached to, and needs those already synced. upstream/target come
    # after: a target is listed per synced upstream (Kong has no global
    # /targets), so upstreams must already be in the read-model.
    # certificate/sni/ca_certificate go last: an SNI's parent is a certificate,
    # so certificates precede them (M5b).
    TYPES_IN_SYNC_ORDER = %w[service consumer route keyauth_credential basicauth_credential plugin upstream target
                             certificate sni ca_certificate].freeze
    CERTIFICATE_TYPES = %w[certificate ca_certificate].freeze

    Result = Struct.new(:synced_count, :removed_count, keyword_init: true) do
      def +(other)
        Result.new(synced_count: synced_count + other.synced_count, removed_count: removed_count + other.removed_count)
      end
    end

    # Syncs every entity type for a connection in dependency order, for
    # the web UI's single "Sync now" button and the sync rake task.
    def self.sync_connection(connection:, client:)
      TYPES_IN_SYNC_ORDER.map { |type| new(connection: connection, client: client, entity_type: type).call }
        .reduce { |total, result| total + result }
    end

    # Re-syncs a single entity already known by kong_id, without a full
    # collection sync -- the write-through step after Kong::ChangeApplier
    # executes a create/update, so the read-model reflects it immediately.
    def self.sync_one(connection:, client:, entity_type:, kong_id:, parent_kong_id: nil)
      path = Kong::EntityTypes.fetch(entity_type).member_path(kong_id, parent_kong_id: parent_kong_id)
      response = client.get(path)
      body = response.body
      raw = body.is_a?(String) ? JSON.parse(body) : body
      new(connection: connection, client: client, entity_type: entity_type).upsert(raw)
    end

    def initialize(connection:, client:, entity_type:)
      @connection = connection
      @client = client
      @entity_type = entity_type
      @definition = Kong::EntityTypes.fetch(entity_type)
      # One per sync run: each plugin's schema is read once, not per row.
      @schema_fields = Kong::PluginSecretFields.new
    end

    def call
      seen_kong_ids = collection_parent_ids.flat_map { |parent_kong_id| sync_collection(parent_kong_id) }

      removed_count = KongEntity.active
        .where(kong_connection: @connection, entity_type: @entity_type)
        .where.not(kong_id: seen_kong_ids)
        .update_all(deleted_at: Time.current)

      Result.new(synced_count: seen_kong_ids.size, removed_count: removed_count)
    end

    def upsert(raw)
      redacted = Kong::Redactor.for_connection(@entity_type, raw, client: @client, schema_fields: @schema_fields)
      metadata = certificate_metadata(raw)
      data = metadata ? cached_certificate_data(redacted[:data], metadata) : redacted[:data]
      now = Time.current
      identity = identify(raw, metadata)

      entity = KongEntity.find_or_initialize_by(
        kong_connection: @connection, entity_type: @entity_type, kong_id: raw.fetch("id")
      )
      entity.first_seen_at ||= now
      entity.assign_attributes(
        name: identity[:name],
        logical_key: identity[:logical_key],
        parent_type: identity[:parent_type],
        parent_kong_id: identity[:parent_kong_id],
        tags: Array(raw["tags"]),
        kong_created_at: from_kong_timestamp(raw["created_at"]),
        kong_updated_at: from_kong_timestamp(raw["updated_at"]),
        enabled: raw["enabled"],
        is_admin_path: @connection.admin_path?(raw.fetch("id")),
        not_after: Kong::CertificateMetadata.not_after_time(metadata),
        data: data,
        digest: redacted[:digest],
        synced_at: now,
        deleted_at: nil
      )
      entity.save!
      entity
    end

    private

    # A flat type has one collection (parent id nil). A nested type (target)
    # has one collection per parent, so it walks every upstream already in the
    # read-model.
    def collection_parent_ids
      return [ nil ] unless @definition.nested?

      KongEntity.active
        .where(kong_connection: @connection, entity_type: @definition.parent_type)
        .pluck(:kong_id)
    end

    # Pages one collection to exhaustion and returns the kong_ids it saw. A
    # parent Kong reports gone mid-sync (deleted since the parent sync ran)
    # simply has no children -- the removal sweep then soft-deletes whatever
    # was cached under it. Any other Admin API error still propagates.
    def sync_collection(parent_kong_id)
      seen = []
      offset = nil

      loop do
        page = fetch_page(offset, parent_kong_id)
        page.fetch("data", []).each do |raw|
          upsert(raw)
          seen << raw.fetch("id")
        end
        offset = page["offset"]
        break if offset.blank?
      end

      seen
    rescue Kong::Client::EntityNotFound
      raise unless @definition.nested?

      []
    end

    # docs/DESIGN.md section 7's identity table, entity_type by entity_type.
    # Route/credential names and logical_keys lean on their parent's already-
    # synced name (falling back to the parent id's first 8 chars if that
    # parent hasn't been synced yet) -- never on a credential's own `key`/
    # `password`, which is exactly what Kong::Redactor strips.
    def identify(raw, metadata = nil)
      case @entity_type
      when "service"
        { name: raw["name"], logical_key: raw["name"], parent_type: nil, parent_kong_id: nil }
      when "route"
        parent_id = raw.dig("service", "id")
        parent_name = parent_name_for(parent_id)
        name = raw["name"] || raw.fetch("id")[0..7]
        { name: name, logical_key: "#{parent_name}/#{name}", parent_type: "service", parent_kong_id: parent_id }
      when "consumer"
        name = raw["username"] || raw["custom_id"]
        { name: name, logical_key: name, parent_type: nil, parent_kong_id: nil }
      when "keyauth_credential", "basicauth_credential"
        parent_id = raw.dig("consumer", "id")
        parent_name = parent_name_for(parent_id)
        name = "#{parent_name}/#{raw.fetch('id')[0..7]}"
        { name: name, logical_key: name, parent_type: "consumer", parent_kong_id: parent_id }
      when "plugin"
        identify_plugin(raw)
      when "upstream"
        { name: raw["name"], logical_key: raw["name"], parent_type: nil, parent_kong_id: nil }
      when "target"
        parent_id = raw.dig("upstream", "id")
        name = raw["target"]
        { name: name, logical_key: "#{parent_name_for(parent_id)}/#{name}", parent_type: "upstream", parent_kong_id: parent_id }
      when "certificate"
        identify_certificate(raw, metadata)
      when "sni"
        { name: raw["name"], logical_key: raw["name"], parent_type: "certificate", parent_kong_id: raw.dig("certificate", "id") }
      when "ca_certificate"
        digest = raw["cert_digest"] || metadata&.dig("fingerprint_sha256") || raw.fetch("id")
        { name: digest[0..11], logical_key: digest, parent_type: nil, parent_kong_id: nil }
      else
        raise ArgumentError, "no identity rule for entity_type #{@entity_type.inspect}"
      end
    end

    # A plugin's scope varies per row -- global, or attached to exactly one
    # of a service/route/consumer (Kong guarantees at most one of the three
    # reference fields is set). Unlike route/credential, the logical_key
    # doesn't resolve the parent's full name (that's a live lookup at
    # render time instead, in the table's Scope column) -- the short id
    # suffix is enough to keep it unique and stable.
    def identify_plugin(raw)
      scope_type = %w[service route consumer].find { |type| raw[type].present? }
      parent_id = scope_type && raw.dig(scope_type, "id")
      scope_label = scope_type ? "#{scope_type}:#{parent_id[0..7]}" : "global"
      name = raw["name"]
      { name: name, logical_key: "#{name}@#{scope_label}", parent_type: scope_type, parent_kong_id: parent_id }
    end

    def certificate_metadata(raw)
      Kong::CertificateMetadata.parse(raw["cert"]) if CERTIFICATE_TYPES.include?(@entity_type)
    end

    # docs/DESIGN.md section 8: cache metadata, not the certificate body.
    def cached_certificate_data(data, metadata)
      data.except("cert", "cert_alt").merge("_metadata" => metadata)
    end

    # DESIGN section 7: first SNI (sorted), else fingerprint[0..11]; the
    # logical_key is the sorted SNI set, else the whole fingerprint.
    def identify_certificate(raw, metadata)
      snis = Array(raw["snis"]).sort
      fingerprint = metadata&.dig("fingerprint_sha256")
      fallback = fingerprint ? fingerprint[0..11] : raw.fetch("id")[0..7]
      key = snis.any? ? snis.join(",") : (fingerprint || raw.fetch("id"))
      { name: snis.first || fallback, logical_key: key, parent_type: nil, parent_kong_id: nil }
    end

    def parent_name_for(parent_kong_id)
      return nil if parent_kong_id.blank?

      parent_name_map[parent_kong_id] || parent_kong_id[0..7]
    end

    def parent_name_map
      @parent_name_map ||= KongEntity.active
        .where(kong_connection: @connection, entity_type: @definition.parent_type)
        .pluck(:kong_id, :name).to_h
    end

    def fetch_page(offset, parent_kong_id)
      params = { size: PAGE_SIZE }
      params[:offset] = offset if offset.present?
      response = @client.get(@definition.collection_path(parent_kong_id: parent_kong_id), params: params)
      body = response.body
      body.is_a?(String) ? JSON.parse(body) : body
    end

    # Kong's Admin API returns created_at/updated_at as epoch seconds.
    def from_kong_timestamp(value)
      return nil if value.blank?

      Time.zone.at(value)
    end
  end
end
