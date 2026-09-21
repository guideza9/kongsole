# Reviews and applies a Kong::ChangePlan -- docs/DESIGN.md section 10, steps
# 5 ("Review") and 6 ("Execute"). Nothing touches Kong until #apply; #show
# is a pure read of the plan already written by Kong::ChangePlanner.
class ChangePlansController < ApplicationController
  before_action :require_session!
  before_action :set_change_plan, except: :index

  # rank >= 2 (uat/prod) requires re-entering the credential immediately
  # before a direct-mode apply, per docs/DESIGN.md section 10 step 5 --
  # defense in depth, since no dev/sit connection actually reaches rank 2
  # under the normal apply_mode convention.
  REAUTH_RANK_THRESHOLD = 2

  # The "PR ค้าง" (outstanding PRs) screen from docs/DESIGN.md section 14 --
  # every PR-mode plan for the current connection, newest first, so pushed
  # branches awaiting review/merge don't just disappear once applied.
  def index
    @change_plans = ChangePlan.where(kong_connection: current_connection, apply_mode: "pr").order(created_at: :desc)
  end

  def show
    @requires_confirmation_name = @change_plan.delete? &&
      Kong::ChangeGuardrails.protected_entity?(current_connection, @change_plan.before)
    @requires_reauth = current_connection.rank >= REAUTH_RANK_THRESHOLD
    @dependent_routes = dependent_routes
    @dependent_targets = dependent_targets
    @env_vars = @change_plan.status == "pending" ? Kong::CertificateKeyPolicy.env_vars_for(@change_plan) : []
    @dependent_snis = dependent_snis
  end

  def apply
    if current_connection.rank >= REAUTH_RANK_THRESHOLD && !reauthenticated?
      return redirect_to(change_plan_path(@change_plan), alert: "Password confirmation failed -- nothing was applied.")
    end

    result = Kong::ChangeApplier.new(
      change_plan: @change_plan, client: current_client,
      actor_username: current_connection.auth_username, actor_operator: current_operator,
      confirmation_name: params[:confirmation_name], secret: current_secret,
      env_acknowledged: params[:acknowledge_env_vars] == "1"
    ).call

    if @change_plan.delete?
      redirect_to entities_path, notice: "Deleted #{result.audit_event.entity_name}."
    else
      redirect_to entity_path_for(@change_plan), notice: "Applied. Recorded in the audit log."
    end
  rescue Kong::ChangeGuardrails::Violation => e
    redirect_to change_plan_path(@change_plan), alert: e.message
  rescue Kong::Client::Error => e
    redirect_to change_plan_path(@change_plan), alert: "Kong rejected this change: #{e.message}"
  rescue Kong::DeckCli::Error, Kong::GitClient::Error => e
    # decK's own message is what an operator needs; the applier has already marked the plan failed.
    redirect_to change_plan_path(@change_plan), alert: Kong::CertificateKeyPolicy.scrub(e.message)
  rescue NotImplementedError => e
    redirect_to change_plan_path(@change_plan), alert: e.message
  end

  private

  def set_change_plan
    @change_plan = ChangePlan.where(kong_connection: current_connection).find(params[:id])
  end

  def reauthenticated?
    return false if params[:password].blank?

    Kong::Client.new(connection: current_connection, secret: params[:password]).get("/")
    true
  rescue Kong::Client::Error
    false
  end

  # docs/DESIGN.md section 15 M3's cascade preview: Kong itself refuses to
  # delete a service that still has routes attached, so surface those routes
  # on the confirmation screen rather than letting the human discover it
  # only after Kong's 409 -- informational only, this does not orchestrate a
  # cascade delete.
  def dependent_routes
    return nil unless @change_plan.delete? && @change_plan.entity_type == "service"

    KongEntity.active.where(kong_connection: current_connection, entity_type: "route", parent_kong_id: @change_plan.target_kong_id)
  end

  # Unlike a service's routes, an upstream's targets are removed *with* it --
  # Kong cascades the delete -- so this is a heads-up about what goes too,
  # not a blocker. Informational only.
  def dependent_targets
    return nil unless @change_plan.delete? && @change_plan.entity_type == "upstream"

    KongEntity.active.where(kong_connection: current_connection, entity_type: "target", parent_kong_id: @change_plan.target_kong_id)
  end

  # Kong removes a certificate's SNIs with it, so this is a heads-up about
  # what goes too, not a blocker.
  def dependent_snis
    return nil unless @change_plan.delete? && @change_plan.entity_type == "certificate"

    KongEntity.active.where(kong_connection: current_connection, entity_type: "sni", parent_kong_id: @change_plan.target_kong_id)
  end

  # Where to land after applying: the entity itself, or -- for a create of a
  # nested type (a new target has no id on the plan yet) -- its parent, which
  # is where the operator started and where the new row now shows.
  def entity_path_for(change_plan)
    entity = KongEntity.active.find_by(kong_connection: current_connection, entity_type: change_plan.entity_type, kong_id: change_plan.target_kong_id)
    return entity_path(entity) if entity

    parent = nested_parent_for(change_plan)
    parent ? entity_path(parent) : entities_path
  end

  def nested_parent_for(change_plan)
    definition = Kong::EntityTypes.fetch(change_plan.entity_type)
    return nil unless definition.requires_parent? && change_plan.parent_kong_id.present?

    KongEntity.active.find_by(kong_connection: current_connection, entity_type: definition.parent_type, kong_id: change_plan.parent_kong_id)
  end
end
