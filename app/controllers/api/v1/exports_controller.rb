module Api
  module V1
    # GET /api/v1/exports (kong_export, R7.4): the same sanitized decK YAML the
    # web export page gives, for an agent -- through Kong::ConfigExport, so
    # there is one sanitizer. The dump uses the connection's stored read
    # credential (a PAT only reaches stored connections) and is audited as the
    # agent, by digest only.
    class ExportsController < BaseController
      before_action :require_connection!

      def index
        result = Kong::ConfigExport.call(
          connection: current_pat_connection, secret: current_pat_connection.auth_secret, select_tags: select_tags,
          actor_username: current_pat.issued_by_username, actor_operator: current_pat.operator, actor_kind: "agent"
        )
        render json: {
          yaml: result.yaml, summary: result.summary, removed: result.removed,
          env_placeholders: result.env_placeholders, matched_nothing: result.matched_nothing
        }
      rescue Kong::ExportSanitizer::Refused => e
        render json: { error: "select_tags: #{e.message}" }, status: :unprocessable_entity
      rescue Kong::DeckCli::Error, Kong::Client::Error, Faraday::Error, Kong::DeckDocument::Unparseable => e
        render json: { error: Kong::CertificateKeyPolicy.scrub(e.message) }, status: :bad_gateway
      end

      private

      # Only a list of strings is a tag list; anything else reads as none, which
      # the sanitizer refuses before decK runs.
      def select_tags
        tags = params[:select_tags]
        tags.is_a?(Array) && tags.all?(String) ? tags : []
      end
    end
  end
end
