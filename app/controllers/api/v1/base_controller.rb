module Api
  module V1
    # Real PAT auth for the MCP-facing API (docs/DESIGN.md section 12) --
    # replaces the temporary session-based auth Api::V1::EntitiesController
    # carried in M1 slice 1. ActionController::API: no session/CSRF
    # machinery needed for a token-authenticated API.
    class BaseController < ActionController::API
      before_action :authenticate_pat!

      private

      def authenticate_pat!
        token = request.headers["Authorization"].to_s[/\ABearer (.+)\z/, 1]
        @current_pat = token.present? ? PersonalAccessToken.authenticate(token) : nil

        render json: { error: "missing or invalid access token" }, status: :unauthorized unless @current_pat
      end

      attr_reader :current_pat

      # Resolves params[:connection] to a KongConnection this PAT is bound
      # to -- the same "connection is a mandatory, non-defaultable
      # parameter on every tool" rule docs/DESIGN.md section 12 states,
      # just keyed off the PAT's connection set instead of one browser
      # session's single active connection.
      def current_pat_connection
        return @current_pat_connection if defined?(@current_pat_connection)

        @current_pat_connection =
          if params[:connection].present?
            current_pat.kong_connections.find_by(name: params[:connection])
          end
      end

      def require_connection!
        return if current_pat_connection

        render json: { error: "connection #{params[:connection].inspect} is required and must be one this token is bound to" },
          status: :unauthorized
      end
    end
  end
end
