module Kong
  # Filter/sort/keyset-paginate kong_entities, per docs/DESIGN.md section 9's
  # API contract. Every sort is resolved through a fixed allowlist and never
  # interpolates caller input into ORDER BY; the cursor is a Rails
  # MessageVerifier-signed (HMAC), tamper-evident token carrying the last
  # row's sort key + id and a digest of the filters that produced it, so a
  # cursor from a different query can't be replayed to skip the WHERE
  # clause -- it's rejected as InvalidCursor instead.
  class EntityQuery
    class InvalidCursor < StandardError; end
    class InvalidSort < StandardError; end

    SORTS = {
      "name" => "name",
      "created_at" => "kong_created_at",
      "updated_at" => "kong_updated_at"
    }.freeze
    # Every (column, direction) keyset condition as a literal string -- not
    # built by interpolating sort_column into a template -- so the SQL
    # fragment is one of these six fixed literals, never assembled from
    # request-shaped input.
    CURSOR_CONDITIONS = {
      [ "name", :asc ] => "(name, id) > (?, ?)",
      [ "name", :desc ] => "(name, id) < (?, ?)",
      [ "kong_created_at", :asc ] => "(kong_created_at, id) > (?, ?)",
      [ "kong_created_at", :desc ] => "(kong_created_at, id) < (?, ?)",
      [ "kong_updated_at", :asc ] => "(kong_updated_at, id) > (?, ?)",
      [ "kong_updated_at", :desc ] => "(kong_updated_at, id) < (?, ?)"
    }.freeze
    DEFAULT_SORT = "-updated_at"
    DEFAULT_LIMIT = 50
    MAX_LIMIT = 200
    FILTER_KEYS = %i[q tags tags_any tags_none created_after created_before updated_after updated_before].freeze

    def initialize(connection:, type:, params: {})
      @connection = connection
      @type = type
      @params = params.symbolize_keys
    end

    def call
      sort_column, direction = parse_sort
      relation = apply_cursor(apply_filters(base_relation), sort_column, direction)
      relation = relation.order(sort_column => direction, id: direction)

      rows = relation.limit(limit + 1).to_a
      has_more = rows.size > limit
      rows = rows.first(limit)

      {
        data: rows,
        has_more: has_more,
        next_cursor: has_more ? build_cursor(rows.last, sort_column, direction) : nil
      }
    end

    private

    def base_relation
      KongEntity.active.where(kong_connection: @connection, entity_type: @type)
    end

    def apply_filters(relation)
      relation = relation.where("name ILIKE ?", "%#{@params[:q]}%") if @params[:q].present?
      relation = relation.where("tags @> ARRAY[?]::text[]", Array(@params[:tags])) if @params[:tags].present?
      relation = relation.where("tags && ARRAY[?]::text[]", Array(@params[:tags_any])) if @params[:tags_any].present?
      relation = relation.where.not("tags && ARRAY[?]::text[]", Array(@params[:tags_none])) if @params[:tags_none].present?
      relation = relation.where("kong_created_at >= ?", @params[:created_after]) if @params[:created_after].present?
      relation = relation.where("kong_created_at <= ?", @params[:created_before]) if @params[:created_before].present?
      relation = relation.where("kong_updated_at >= ?", @params[:updated_after]) if @params[:updated_after].present?
      relation = relation.where("kong_updated_at <= ?", @params[:updated_before]) if @params[:updated_before].present?
      relation
    end

    def parse_sort
      raw = sort_raw
      desc = raw.start_with?("-")
      key = desc ? raw[1..] : raw
      column = SORTS[key] or raise InvalidSort, "invalid sort key: #{key.inspect} (allowed: #{SORTS.keys.join(', ')})"
      [ column, desc ? :desc : :asc ]
    end

    def sort_raw
      @params[:sort].presence || DEFAULT_SORT
    end

    def apply_cursor(relation, sort_column, direction)
      return relation if @params[:cursor].blank?

      payload = decode_cursor(@params[:cursor])
      raise InvalidCursor, "cursor was issued for a different sort" unless payload["s"] == sort_raw
      raise InvalidCursor, "cursor was issued for different filters" unless payload["f"] == filter_digest

      last_value, last_id = payload["k"]
      condition = CURSOR_CONDITIONS.fetch([ sort_column, direction ])
      relation.where(condition, last_value, last_id)
    end

    def build_cursor(last_row, sort_column, _direction)
      payload = { "k" => [ last_row.public_send(sort_column), last_row.id ], "s" => sort_raw, "f" => filter_digest }
      verifier.generate(payload)
    end

    def decode_cursor(cursor)
      verifier.verify(cursor)
    rescue ActiveSupport::MessageVerifier::InvalidSignature
      raise InvalidCursor, "cursor is invalid, expired, or was tampered with"
    end

    # A dedicated verifier with Marshal serialization, not
    # Rails.application.message_verifier's JSON default: JSON round-trips a
    # Time through an ISO8601 string, which loses enough precision that two
    # rows genuinely tied on the sort column can decode as "not equal" and
    # silently break the id tiebreak. Marshal preserves the exact value
    # ActiveRecord loaded.
    def verifier
      ActiveSupport::MessageVerifier.new(
        Rails.application.key_generator.generate_key("kong_entity_query_cursor"),
        serializer: Marshal
      )
    end

    def filter_digest
      Digest::SHA256.hexdigest(@params.slice(*FILTER_KEYS).to_json)
    end

    def limit
      requested = @params[:limit].to_i
      return DEFAULT_LIMIT if requested <= 0

      [ requested, MAX_LIMIT ].min
    end
  end
end
