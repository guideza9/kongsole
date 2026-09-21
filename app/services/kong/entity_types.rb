module Kong
  # Central per-entity-type Admin API path config -- docs/DESIGN.md section
  # 15 (M3): the single place that knows the collection path for
  # list/get/patch/delete, and (when it differs) the path to create under.
  # Kong::EntitySync, Kong::ChangePlanner, and Kong::ChangeApplier all
  # resolve paths through this instead of each hardcoding `/services`.
  module EntityTypes
    # Fields Kong owns and assigns itself -- never sent back on a write, and
    # never rendered into decK YAML or the JSON editor.
    KONG_MANAGED_FIELDS = %w[id created_at updated_at].freeze

    # `list_path` is the flat, top-level collection. A type whose Admin API
    # only exists under its parent (a target -- Kong has no global
    # `GET /targets`) sets `nested_collection_proc` instead, and every
    # read/patch/delete resolves through the parent id. Callers use
    # collection_path/member_path and never build a path from list_path.
    #
    # `schema_name` is Kong's `/schemas/:name` -- when set, Kong::ChangePlanner
    # runs `POST /schemas/:name/validate` at plan time so a malformed body is
    # rejected with Kong's own per-field errors before a plan exists.
    Definition = Struct.new(:list_path, :parent_type, :create_path_proc, :nested_collection_proc, :schema_name,
                             :parent_in_body, :deck_collection, :deck_key, :deck_refs, keyword_init: true) do
      # M5c. Where an entity of this type lives in decK YAML, what identifies
      # it there, and which Kong-JSON fields point at the parent it is nested
      # inside (dropped when rendering: decK wants the nesting, not the ref).
      # A type with no `deck_collection` is never rendered.
      def deck_supported?
        deck_collection.present?
      end

      def deck_refs
        self[:deck_refs] || []
      end

      def nested?
        nested_collection_proc.present?
      end

      # A flat child (sni) still needs its parent: the create body must carry
      # `certificate: {id}`. `nested?` types (target) need it for the path.
      def requires_parent?
        nested? || parent_in_body.present?
      end

      def collection_path(parent_kong_id: nil)
        return list_path unless nested?

        require_parent!(parent_kong_id)
        nested_collection_proc.call(parent_kong_id)
      end

      def member_path(kong_id, parent_kong_id: nil)
        "#{collection_path(parent_kong_id: parent_kong_id)}/#{kong_id}"
      end

      def create_path(parent_kong_id: nil)
        return create_path_proc.call(parent_kong_id) if create_path_proc

        collection_path(parent_kong_id: parent_kong_id)
      end

      private

      def require_parent!(parent_kong_id)
        return if parent_kong_id.present?

        raise ArgumentError, "a #{parent_type}-nested entity needs its parent_kong_id to build a path"
      end
    end

    # Kong 3.x's top-level `POST /routes` accepts `service: {id: ...}` in the
    # body, so routes don't need a nested create path the way credentials do.
    DEFINITIONS = {
      "service" => Definition.new(list_path: "/services", parent_type: nil, deck_collection: "services", deck_key: "name"),
      "route" => Definition.new(list_path: "/routes", parent_type: "service", deck_collection: "routes", deck_key: "name",
                                 deck_refs: %w[service]),
      "consumer" => Definition.new(list_path: "/consumers", parent_type: nil, deck_collection: "consumers", deck_key: "username"),
      # Global `/key-auths` and `/basic-auths` list/get/patch/delete any
      # credential by id; creation needs a specific consumer to attach to,
      # hence the nested create_path_proc. No deck_collection: a credential is
      # never rendered into decK YAML (docs/DESIGN.md section 1.7).
      "keyauth_credential" => Definition.new(
        list_path: "/key-auths", parent_type: "consumer",
        create_path_proc: ->(parent_kong_id) { "/consumers/#{parent_kong_id}/key-auth" }
      ),
      "basicauth_credential" => Definition.new(
        list_path: "/basic-auths", parent_type: "consumer",
        create_path_proc: ->(parent_kong_id) { "/consumers/#{parent_kong_id}/basic-auth" }
      ),
      # Kong's `POST /plugins` is flat regardless of scope -- the target
      # (service/route/consumer, or none for global) goes *in the body*, not
      # in the path, so no create_path_proc is needed the way credentials
      # need one. `parent_type: nil` here is deliberate, not "no parent
      # like service/consumer": a plugin's scope varies per row (global, or
      # attached to any of three different types), so the registry has no
      # single fixed answer the way every other type does -- see
      # Kong::EntitySync#identify's "plugin" branch, which resolves it per
      # instance instead. decK nests it under whichever of the three it is
      # scoped to (Kong::DeckRenderer resolves that per plan).
      "plugin" => Definition.new(list_path: "/plugins", parent_type: nil, deck_collection: "plugins", deck_key: "name",
                                  deck_refs: %w[service route consumer]),
      "upstream" => Definition.new(list_path: "/upstreams", parent_type: nil, schema_name: "upstreams",
                                    deck_collection: "upstreams", deck_key: "name"),
      # Kong 3.7 targets are ordinary mutable entities (PATCH/DELETE work,
      # duplicates 409), but there is no global collection -- everything
      # lives under the upstream, so `nested_collection_proc` and no list_path.
      # decK accepts a target only nested under its upstream (top-level
      # `targets:` is rejected -- measured, M5c).
      "target" => Definition.new(
        parent_type: "upstream",
        nested_collection_proc: ->(upstream_kong_id) { "/upstreams/#{upstream_kong_id}/targets" },
        schema_name: "targets", deck_collection: "targets", deck_key: "target", deck_refs: %w[upstream]
      ),
      # M5b. All three are flat top-level collections in Kong 3.7 -- unlike a
      # target, an SNI is listable and addressable without its certificate.
      # In decK YAML a certificate is identified by `id` (decK requires it on
      # certificates, and only there), an SNI nests under it, and a CA
      # certificate matches by `id` when present, else by its cert text.
      "certificate" => Definition.new(list_path: "/certificates", parent_type: nil, schema_name: "certificates",
                                       deck_collection: "certificates", deck_key: "id"),
      "sni" => Definition.new(list_path: "/snis", parent_type: "certificate", schema_name: "snis", parent_in_body: true,
                               deck_collection: "snis", deck_key: "name", deck_refs: %w[certificate]),
      "ca_certificate" => Definition.new(list_path: "/ca_certificates", parent_type: nil, schema_name: "ca_certificates",
                                          deck_collection: "ca_certificates", deck_key: "id")
    }.freeze

    # What a human calls an entity: its `name`, or -- for a target, which has
    # none -- its `host:port`, or -- for a certificate, which has none -- its
    # first SNI in sorted order. Takes several documents (before, after) and
    # returns the first label present, since a create has no `before`.
    def self.label(*documents)
      documents.each do |doc|
        label = doc && (doc["name"].presence || doc["target"].presence || Array(doc["snis"]).min.presence)
        return label if label
      end
      nil
    end

    def self.fetch(entity_type)
      DEFINITIONS.fetch(entity_type) { raise ArgumentError, "unknown entity_type #{entity_type.inspect}" }
    end
  end
end
