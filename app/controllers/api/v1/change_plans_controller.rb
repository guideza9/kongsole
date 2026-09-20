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
      # Every type the registry knows -- derived, not listed, so a new entity
      # type can't be added to Kong::EntityTypes and silently stay unwritable
      # over the agent path.
      SUPPORTED_TYPES = Kong::EntityTypes::DEFINITIONS.keys.freeze

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
      rescue Kong::ChangePlanner::InvalidChange => e
        render json: { error: safe_message(e.message) }, status: :unprocessable_entity
      rescue Kong::ChangeGuardrails::Violation => e
        render json: { error: safe_message(e.message) }, status: :forbidden
      rescue Kong::Client::EntityNotFound
        render json: { error: "entity not found" }, status: :not_found
      rescue Kong::Client::Error => e
        render json: { error: safe_message("Kong rejected this request: #{e.message}") }, status: :bad_gateway
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
          secret: plan.kong_connection.auth_secret,
          env_acknowledged: env_acknowledged?
        ).call

        render json: { id: plan.id, status: plan.reload.status, audit_event_id: result.audit_event.id }
      rescue ActiveRecord::RecordNotFound
        render json: { error: "change plan not found" }, status: :not_found
      rescue Kong::ChangeGuardrails::Violation => e
        render json: { error: safe_message(e.message) }, status: :forbidden
      rescue Kong::Client::Error => e
        render json: { error: safe_message("Kong rejected this request: #{e.message}") }, status: :bad_gateway
      rescue NotImplementedError => e
        render json: { error: safe_message(e.message) }, status: :unprocessable_entity
      end

      private

      # The applier only honours a literal `true`, so this must be a strict
      # boolean: JSON true, or the form-encoded strings "true"/"1". Anything
      # else -- absent, false, "0", "false", "yes", an Array or hash -- is a
      # refusal. (ActiveModel's Boolean cast is deliberately not used: it
      # casts an Array to true.)
      def env_acknowledged?
        value = params[:acknowledge_env_vars]
        value == true || (value.is_a?(String) && %w[true 1].include?(value))
      end

      # Kong's and the planner's messages can quote the document they refused,
      # which for a certificate may hold a private key: same scrub as the web.
      def safe_message(message)
        Kong::CertificateKeyPolicy.scrub(message)
      end

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
          "target_kong_id" => plan.target_kong_id, "parent_kong_id" => plan.parent_kong_id,
          "diff" => plan.diff, "status" => plan.status,
          "expires_at" => plan.expires_at.iso8601
        }
      end
    end
  end
end
