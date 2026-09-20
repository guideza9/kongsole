module Api
  module V1
    # GET /api/v1/entities -- read path per docs/DESIGN.md section 9, the
    # backing endpoint for the eventual `kong_search` MCP tool.
    class EntitiesController < BaseController
      SUMMARY_FIELDS = %w[id kong_id name tags enabled is_admin_path created_at updated_at].freeze

      before_action :require_connection!
      before_action :require_type!

      def index
        result = Kong::EntityQuery.new(connection: current_pat_connection, type: params[:type], params: query_params).call
        render json: {
          data: result[:data].map { |entity| serialize(entity) },
          meta: meta(result)
        }
      rescue Kong::EntityQuery::InvalidCursor, Kong::EntityQuery::InvalidSort => e
        render json: { error: e.message }, status: :bad_request
      end

      private

      def require_type!
        return if performed?
        return if params[:type].present?

        render json: { error: "type is required" }, status: :bad_request
      end

      def query_params
        params.permit(:q, :sort, :cursor, :limit, :created_after, :created_before, :updated_after, :updated_before,
                       tags: [], tags_any: [], tags_none: []).to_h.symbolize_keys
      end

      def serialize(entity)
        fields = params[:fields].present? ? (params[:fields].split(",") & SUMMARY_FIELDS) : SUMMARY_FIELDS
        full = {
          "id" => entity.id, "kong_id" => entity.kong_id, "name" => entity.name, "tags" => entity.tags,
          "enabled" => entity.enabled, "is_admin_path" => entity.is_admin_path,
          "created_at" => entity.kong_created_at&.iso8601, "updated_at" => entity.kong_updated_at&.iso8601
        }
        full.slice(*fields)
      end

      def meta(result)
        synced_at = KongEntity.active.where(kong_connection: current_pat_connection, entity_type: params[:type]).maximum(:synced_at)
        {
          has_more: result[:has_more],
          next_cursor: result[:next_cursor],
          connection: current_pat_connection.name,
          credential_mode: current_pat_connection.credential_mode,
          access_level: current_pat_connection.access_level,
          credential_kind: current_pat_connection.credential_kind,
          synced_at: synced_at&.iso8601,
          stale_seconds: synced_at ? (Time.current - synced_at).round : nil
        }
      end
    end
  end
end
