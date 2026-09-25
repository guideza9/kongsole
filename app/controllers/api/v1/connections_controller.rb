module Api
  module V1
    # GET /api/v1/connections -- the backing endpoint for the `kong_connections`
    # MCP tool (docs/DESIGN.md section 12): every connection this token is
    # bound to. Drift is omitted -- that's M6 work, not built yet.
    class ConnectionsController < BaseController
      def index
        render json: {
          data: current_pat.kong_connections.order(:rank, :name).map { |connection| serialize(connection) }
        }
      end

      private

      def serialize(connection)
        {
          "name" => connection.name, # project/env -- what every other tool takes as `connection`
          "project" => connection.project&.key,
          "env" => connection.env,
          "rank" => connection.rank,
          "apply_mode" => connection.apply_mode,
          "access_level" => connection.access_level,
          "credential_mode" => connection.credential_mode,
          "kong_version" => connection.kong_version
        }
      end
    end
  end
end
