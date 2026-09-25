# R2: what the service and route forms do once their form object is valid --
# propose the create, then land where that change is reviewed: the plan
# review (direct) or the changeset it joined (PR). A refusal re-renders the
# form with what was typed, the reason at the top.
module ProposesFromForm
  extend ActiveSupport::Concern

  private

  def propose_from_form(entity_type:, attributes:, parent_kong_id: nil)
    plan = Kong::ChangePlanner.new(
      connection: current_connection, client: current_client, operation: "create", entity_type: entity_type,
      parent_kong_id: parent_kong_id, attributes: attributes,
      actor_username: current_connection.auth_username, actor_operator: current_operator
    ).call

    if plan.changeset
      redirect_to changeset_path(plan.changeset), notice: "Added to changeset: create #{entity_type} #{plan.entity_label}."
    else
      redirect_to change_plan_path(plan)
    end
  rescue Kong::ChangeGuardrails::Violation => e
    @form.errors.add(:base, e.message)
    render :new, status: :unprocessable_entity
  rescue Kong::Client::Error => e
    # R3.2: Kong's own error, explained (cause and next step).
    explanation = explain_error(e)
    flash.now[:alert] = explanation.title
    flash.now[:error_explanation] = explanation.to_flash
    render :new, status: :unprocessable_entity
  end
end
