module Kong
  # What the read-model calls an entity, for the renderer: a decK YAML entry is
  # nested under its parent by the parent's *name* (service, upstream,
  # consumer), and a plugin scoped to a route needs the route's service too.
  # Kong's own uuids are not in the file, so the read-model is the bridge.
  # Everything is scoped to one connection and skips soft-deleted rows; an
  # unknown or malformed id answers nil, never raises.
  class DeckReadModelResolver
    def initialize(connection)
      @connection = connection
    end

    def name_of(kong_id)
      entity(kong_id)&.name
    end

    def parent_of(kong_id)
      entity(kong_id)&.parent_kong_id
    end

    private

    def entity(kong_id)
      return nil if @connection.nil? || kong_id.blank?

      KongEntity.active.find_by(kong_connection: @connection, kong_id: kong_id)
    end
  end
end
