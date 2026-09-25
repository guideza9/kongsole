# R2: "New service" -- a form (ServiceForm) instead of the JSON editor. The
# body it builds goes through Kong::ChangePlanner like every other change:
# a direct env opens the plan review, a PR env adds an item to the open
# changeset (R8) and writes nothing to Kong.
class ServicesController < ApplicationController
  include ProposesFromForm

  before_action :require_session!
  before_action -> { require_writable!(back_to: entities_path(type: "service")) }

  def new
    @form = ServiceForm.new
  end

  def create
    @form = ServiceForm.new(service_params)
    return render(:new, status: :unprocessable_entity) unless @form.valid?

    propose_from_form(entity_type: "service", attributes: @form.to_attributes(select_tags: current_connection.select_tags))
  end

  private

  def service_params
    params.require(:service_form).permit(:name, :protocol, :host, :port, :path, :retries,
      :connect_timeout, :read_timeout, :write_timeout, :enabled, :tags)
  end
end
