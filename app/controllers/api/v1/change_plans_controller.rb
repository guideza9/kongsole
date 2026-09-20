module Api
  module V1
    # POST /api/v1/change_plans (kong_plan) and POST /api/v1/change_plans/:id/apply
    # (kong_apply) -- docs/DESIGN.md section 10 steps 4 and 6, driven by an
    # agent instead of the web UI. Thin wrappers around the same
    # Kong::ChangePlanner/Kong::ChangeApplier the human write path (M1
    # slice 2) uses, with the two agent-specific guardrails section 12
    # names on top of the shared ones: an absolute admin-path/protected
    # delete block (Kong::ChangeGuardrails, actor_kind: "agent") and a hard
    # rank>=2-direct-mode block on apply, checked here because an agent has
    # no interactive re-auth channel the way the web UI's rank>=2 flow does.
    class ChangePlansController < BaseController
      REAUTH_RANK_THRESHOLD = 2
      SUPPORTED_TYPES = %w[service route consumer keyauth_credential basicauth_credential plugin].freeze

      before_action :require_connection!

      def create
        unless SUPPORTED_TYPES.include?(params[:type])
          return render json: { error: "type must be one of: #{SUPPORTED_TYPES.join(', ')}" }, status: :bad_request
        end

        plan = Kong::ChangePlanner.new(
          connection: current_pat_connection, client: client_for(current_pat_connection),
          operation: params[:operation], entity_type: params[:type], target_kong_id: params[:target_kong_id],
          parent_kong_id: params[:parent_kong_id], attributes: raw_attributes,
          actor_username: current_pat.issued_by_username, actor_operator: current_pat.operator,
          actor_kind: "agent"
        ).call

        render json: serialize_plan(plan), status: :created
      rescue Kong::ChangeGuardrails::Violation => e
        render json: { error: e.message }, status: :forbidden
      rescue Kong::Client::EntityNotFound
        render json: { error: "entity not found" }, status: :not_found
      rescue Kong::Client::Error => e
        render json: { error: "Kong rejected this request: #{e.message}" }, status: :bad_gateway
      end

      def apply
        plan = ChangePlan.where(kong_connection: current_pat_connection).find(params[:id])

        if plan.kong_connection.rank >= REAUTH_RANK_THRESHOLD && plan.kong_connection.apply_mode == "direct"
          return render json: {
            error: "connection is rank #{plan.kong_connection.rank} on apply_mode direct -- the agent path can only " \
              "write here once it's PR mode (docs/DESIGN.md section 12: kong_apply on rank>=2 requires PR mode)"
          }, status: :forbidden
        end

        result = Kong::ChangeApplier.new(
          change_plan: plan, client: client_for(plan.kong_connection),
          actor_username: current_pat.issued_by_username, actor_operator: current_pat.operator,
          secret: plan.kong_connection.auth_secret
        ).call

        render json: { id: plan.id, status: plan.reload.status, audit_event_id: result.audit_event.id }
      rescue ActiveRecord::RecordNotFound
        render json: { error: "change plan not found" }, status: :not_found
      rescue Kong::ChangeGuardrails::Violation => e
        render json: { error: e.message }, status: :forbidden
      rescue Kong::Client::Error => e
        render json: { error: "Kong rejected this request: #{e.message}" }, status: :bad_gateway
      rescue NotImplementedError => e
        render json: { error: e.message }, status: :unprocessable_entity
      end

      private

      def raw_attributes
        value = params[:attributes]
        value.respond_to?(:to_unsafe_h) ? value.to_unsafe_h : (value || {})
      end

      def client_for(connection)
        Kong::Client.new(connection: connection, secret: connection.auth_secret)
      end

      def serialize_plan(plan)
        {
          "id" => plan.id, "operation" => plan.operation, "entity_type" => plan.entity_type,
          "target_kong_id" => plan.target_kong_id, "diff" => plan.diff, "status" => plan.status,
          "expires_at" => plan.expires_at.iso8601
        }
      end
    end
  end
end
