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
                             keyword_init: true) do
      def nested?
        nested_collection_proc.present?
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
      "service" => Definition.new(list_path: "/services", parent_type: nil),
      "route" => Definition.new(list_path: "/routes", parent_type: "service"),
      "consumer" => Definition.new(list_path: "/consumers", parent_type: nil),
      # Global `/key-auths` and `/basic-auths` list/get/patch/delete any
      # credential by id; creation needs a specific consumer to attach to,
      # hence the nested create_path_proc.
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
      # instance instead.
      "plugin" => Definition.new(list_path: "/plugins", parent_type: nil),
      "upstream" => Definition.new(list_path: "/upstreams", parent_type: nil, schema_name: "upstreams"),
      # Kong 3.7 targets are ordinary mutable entities (PATCH/DELETE work,
      # duplicates 409), but there is no global collection -- everything
      # lives under the upstream, so `nested_collection_proc` and no list_path.
      "target" => Definition.new(
        parent_type: "upstream",
        nested_collection_proc: ->(upstream_kong_id) { "/upstreams/#{upstream_kong_id}/targets" },
        schema_name: "targets"
      )
    }.freeze

    # What a human calls an entity: its `name`, or -- for a target, which has
    # none -- its `host:port`. Takes several documents (before, after) and
    # returns the first label present, since a create has no `before`.
    def self.label(*documents)
      documents.each do |doc|
        label = doc && (doc["name"].presence || doc["target"].presence)
        return label if label
      end
      nil
    end

    def self.fetch(entity_type)
      DEFINITIONS.fetch(entity_type) { raise ArgumentError, "unknown entity_type #{entity_type.inspect}" }
    end
  end
end
