module Api
  module V1
    # GET /api/v1/certificates/expiring -- the backing endpoint for the
    # `kong_certs_expiring` MCP tool (docs/DESIGN.md section 8/12). Unlike the
    # web dashboard (one session, one connection), this spans every connection
    # the *token* is bound to: an agent asking "what expires soon" means across
    # the estate. Metadata only -- never a key, never a PEM.
    class CertificatesController < BaseController
      DEFAULT_DAYS = 30
      MAX_DAYS = 3650

      def expiring
        connections = scoped_connections
        return unless connections

        days = normalized_days
        entities = KongEntity.active
          .where(kong_connection: connections, entity_type: %w[certificate ca_certificate])
          .expiring_within(days).includes(:kong_connection).order(:not_after, :id)

        render json: {
          data: entities.map { |entity| serialize(entity) },
          meta: { days: days, connections: connections.map(&:name), generated_at: Time.current.iso8601 }
        }
      end

      private

      # A query string can smuggle an Array (`connection[]=x`) or a hash
      # (`connection[a]=x`) into params; only a String is a connection name.
      # Anything else is refused like any other connection the token isn't
      # bound to, rather than reaching the query and raising.
      def scoped_connections
        raw = params[:connection]
        return current_pat.kong_connections.order(:rank, :name).to_a if raw.nil? || (raw.is_a?(String) && raw.blank?)

        connection = raw.is_a?(String) ? current_pat.kong_connections.find_by(name: raw) : nil
        return [ connection ] if connection

        render json: { error: connection_error_message }, status: :unauthorized
        nil
      end

      # Only a String is a day count; an Array/Parameters (`days[]=1`) has no
      # meaningful #to_i, so it falls back to the default like any nonsense.
      def normalized_days
        raw = params[:days]
        days = raw.is_a?(String) ? raw.to_i : 0
        days.between?(1, MAX_DAYS) ? days : DEFAULT_DAYS
      end

      def serialize(entity)
        {
          "connection" => entity.kong_connection.name, "type" => entity.entity_type, "name" => entity.name,
          "kong_id" => entity.kong_id, "snis" => Array(entity.data["snis"]),
          "not_after" => entity.not_after.iso8601, "days_left" => ((entity.not_after - Time.current) / 1.day).floor,
          "status" => entity.expiry_status
        }
      end
    end
  end
end
