# Reviews and applies a Kong::ChangePlan -- docs/DESIGN.md section 10, steps
# 5 ("Review") and 6 ("Execute"). Nothing touches Kong until #apply; #show
# is a pure read of the plan already written by Kong::ChangePlanner.
class ChangePlansController < ApplicationController
  include Reauthentication

  before_action :require_session!
  before_action :set_change_plan, except: :index

  # The "PR ค้าง" (outstanding PRs) screen from docs/DESIGN.md section 14 --
  # every PR-mode plan for the current connection, newest first, so pushed
  # branches awaiting review/merge don't just disappear once applied. On a
  # PR-mode connection those live in changesets now (R8.8).
  def index
    return redirect_to(changesets_path) if current_connection.apply_mode == "pr"

    @change_plans = ChangePlan.where(kong_connection: current_connection, apply_mode: "pr").order(created_at: :desc)
  end

  def show
    @protected_entity = @change_plan.delete? &&
      Kong::ChangeGuardrails.protected_entity?(current_connection, @change_plan.before)
    @requires_confirmation_name = @protected_entity || (@change_plan.delete? && current_connection.protected_env?)
    @requires_reauth = requires_reauth?
    @requires_env_name = current_connection.protected_env?
    @dependent_routes = dependent_routes
    @dependent_targets = dependent_targets
    @env_vars = @change_plan.status == "pending" ? Kong::CertificateKeyPolicy.env_vars_for(@change_plan) : []
    @deck_env_vars = @change_plan.status == "pending" ? Kong::CertificateKeyPolicy.deck_vars_for(@change_plan) : []
    @dependent_snis = dependent_snis
    @actionable = @change_plan.status == "pending" && !@change_plan.expired? && !@change_plan.in_changeset?
    @guardrails = @actionable ? guardrails_for(@change_plan) : []
    # Where an applied plan goes next: the record it left in the audit log, and
    # the entity it changed (nothing to open after a delete).
    if @change_plan.status == "applied"
      @audit_event = AuditEvent.find_by(change_plan_id: @change_plan.id)
      @applied_entity = entity_for(@change_plan) unless @change_plan.delete?
    end
  end

  def apply
    # R8: an item of a changeset leaves only when a person submits that changeset.
    if @change_plan.changeset
      return redirect_to(changeset_path(@change_plan.changeset),
        alert: "This plan is item #{@change_plan.position} of changeset ##{@change_plan.changeset_id} -- submit the changeset to push it.")
    end

    unless env_name_confirmed?
      return redirect_to(change_plan_path(@change_plan), alert: "Connection name didn't match -- nothing was applied.")
    end

    if requires_reauth? && !reauthenticated?
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
    # A guardrail refuses *before* anything is attempted, so the plan is still
    # pending and the page has nothing of its own to say -- the flash is the
    # only place this message can live.
    redirect_to change_plan_path(@change_plan), alert: e.message
  rescue Kong::Client::Error, Kong::DeckCli::Error, Kong::GitClient::Error
    # No flash: the applier has already marked the plan failed and stored the
    # scrubbed reason, so the failed banner states it in full and keeps
    # stating it on every later visit. A flash here would stack a second red
    # banner saying the same thing, directly above it.
    redirect_to change_plan_path(@change_plan)
  rescue NotImplementedError => e
    redirect_to change_plan_path(@change_plan), alert: e.message
  end

  # One line of the review page's Guardrails list. state is :pass (already
  # checked and clear), :confirm (the operator must act in the action bar
  # before Apply works) or :warn (a heads-up that needs a human read).
  Guardrail = Struct.new(:state, :label, :detail)

  private

  # What the write path checks for this plan, as the operator sees it. The
  # write-access and plugin checks already ran when the plan was proposed
  # (no plan exists otherwise) and re-run on apply; the rest are collected
  # from the same flags #show already computed, so this list cannot say
  # something the apply path will not enforce.
  def guardrails_for(plan)
    list = []

    list << if plan.apply_mode == "pr"
      Guardrail.new(:pass, "No live write", "This pushes a branch for review; Kong changes only after it is merged.")
    elsif current_connection.access_level == "rw"
      Guardrail.new(:pass, "Credential can write", "This login has read-write access to Kong's Admin API.")
    else
      Guardrail.new(:warn, "Credential can't write", "Access level is #{current_connection.access_level || 'unknown'}; Kong will refuse this apply.")
    end

    protected_entity = plan.before.present? && Kong::ChangeGuardrails.protected_entity?(current_connection, plan.before)
    list << if protected_entity && plan.delete?
      Guardrail.new(:confirm, "Protected entity", "Part of the tool's own admin path, or tagged protected. Type its name to delete it.")
    elsif protected_entity
      Guardrail.new(:warn, "Protected entity", "Part of the tool's own admin path, or tagged protected. Edit with care.")
    else
      Guardrail.new(:pass, "Not on the admin path", "Not tagged protected, and not the route the tool reaches Kong through.")
    end
    list << Guardrail.new(:confirm, "Entity name", "Retype #{plan.entity_label} to confirm you mean to delete it from #{helpers.env_display_name(current_connection)}.") if @requires_confirmation_name && !@protected_entity

    env_name = helpers.env_display_name(current_connection)
    # Names it as the *connection* name: the field compares against
    # connection.name, which need not read like the environment the rest of
    # this page now spells out ("kong-prod-admin" vs "Production").
    list << Guardrail.new(:confirm, "Connection name", "Retype the connection name #{current_connection.name} to confirm you mean #{env_name}.") if @requires_env_name
    if @requires_reauth
      # PR mode writes nothing: the credential is what diffs the rendered YAML
      # against Kong, so promising "for every write" would contradict the
      # branch-push copy this same page shows.
      detail = if plan.apply_mode == "pr"
        "Re-enter your Kong password; it diffs this change against #{env_name} before the branch is pushed."
      else
        "Re-enter your Kong password; #{env_name} needs a fresh credential for every write."
      end
      list << Guardrail.new(:confirm, "Password", detail)
    end
    list << Guardrail.new(:confirm, "Certificate key variables", "Confirm #{@env_vars.join(', ')} #{@env_vars.size == 1 ? 'is' : 'are'} set on every Kong node.") if @env_vars.present?
    list << Guardrail.new(:warn, "decK CI variable", "#{@deck_env_vars.join(', ')} must be set in CI, or the sync fails before it reaches Kong.") if @deck_env_vars.present?

    list
  end

  def set_change_plan
    @change_plan = ChangePlan.where(kong_connection: current_connection).find(params[:id])
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
    entity = entity_for(change_plan)
    entity ? entity_path(entity) : entities_path
  end

  # The entity itself, or its parent for a nested create; nil when neither is
  # in the read-model.
  def entity_for(change_plan)
    KongEntity.active.find_by(kong_connection: current_connection, entity_type: change_plan.entity_type, kong_id: change_plan.target_kong_id) ||
      nested_parent_for(change_plan)
  end

  def nested_parent_for(change_plan)
    definition = Kong::EntityTypes.fetch(change_plan.entity_type)
    return nil unless definition.requires_parent? && change_plan.parent_kong_id.present?

    KongEntity.active.find_by(kong_connection: current_connection, entity_type: definition.parent_type, kong_id: change_plan.parent_kong_id)
  end
end
