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

    Definition = Struct.new(:list_path, :parent_type, :create_path_proc, keyword_init: true) do
      def create_path(parent_kong_id: nil)
        create_path_proc ? create_path_proc.call(parent_kong_id) : list_path
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
      "plugin" => Definition.new(list_path: "/plugins", parent_type: nil)
    }.freeze

    def self.fetch(entity_type)
      DEFINITIONS.fetch(entity_type) { raise ArgumentError, "unknown entity_type #{entity_type.inspect}" }
    end
  end
end
