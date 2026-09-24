# The "Add plugin" web flow -- docs/DESIGN.md section 15 M4. Two steps of
# #new (catalog -> config editor) and one #create, all scoped by
# scope_type/scope_kong_id carried through as params from wherever the flow
# was entered (a service/route/consumer's show page, or entities#index's
# Plugins tab for a global plugin) -- there is no free-text entity picker,
# since the scope is always inherited from where the operator already was.
#
# The config editor reuses the same JSON document editor
# EntitiesController#edit's Full JSON panel uses, seeded from the plugin's
# live schema instead of a live entity; #create hands the parsed result
# straight to Kong::ChangePlanner, landing on the same review -> apply ->
# audit pipeline as every other create.
class PluginsController < ApplicationController
  include JsonPayloadParsing

  before_action :require_session!

  def new
    @scope_type = params[:scope_type].presence
    @scope_kong_id = params[:scope_kong_id].presence
    @scope_label = scope_label

    if params[:plugin_name].present?
      @plugin_name = params[:plugin_name]
      @schema = fetch_schema(@plugin_name)
      @payload_json = JSON.pretty_generate(seed_payload(@plugin_name, @schema))
    else
      @catalog = current_connection.plugins_available.fetch("available_on_server", {}).keys.sort
    end
  rescue Kong::Client::Error => e
    explain_kong_error(e)
    redirect_to new_plugin_path(scope_type: @scope_type, scope_kong_id: @scope_kong_id),
      alert: "Couldn't load the plugin schema from Kong: #{e.message}"
  end

  def create
    attributes = parse_json_payload!(params[:payload_json], entity_type: "plugin")
    attributes[params[:scope_type]] = { "id" => params[:scope_kong_id] } if params[:scope_type].present?

    plan = Kong::ChangePlanner.new(
      connection: current_connection, client: current_client, operation: "create", entity_type: "plugin",
      parent_kong_id: params[:scope_kong_id].presence, attributes: attributes,
      actor_username: current_connection.auth_username, actor_operator: current_operator
    ).call
    redirect_to change_plan_path(plan)
  rescue JsonPayloadParsing::InvalidPayload => e
    render_config_step_with_error(e.message)
  rescue Kong::ChangeGuardrails::Violation => e
    redirect_to new_plugin_path(scope_type: params[:scope_type], scope_kong_id: params[:scope_kong_id]), alert: e.message
  rescue Kong::Client::Error => e
    explain_kong_error(e)
    redirect_to new_plugin_path(scope_type: params[:scope_type], scope_kong_id: params[:scope_kong_id]),
      alert: Kong::ErrorExplanation.for(e).title
  end

  private

  # R3: the cause and next step behind the alert (Kong::ErrorExplanation).
  def explain_kong_error(error)
    flash[:error_explanation] = Kong::ErrorExplanation.for(error).to_flash
  end

  # Re-renders the config step (not a redirect) so the operator's edit
  # survives the round trip, same contract as EntitiesController#update's
  # JSON branch.
  def render_config_step_with_error(message)
    @scope_type = params[:scope_type].presence
    @scope_kong_id = params[:scope_kong_id].presence
    @scope_label = scope_label
    @plugin_name = params[:plugin_name]
    @payload_json = params[:payload_json]
    @payload_error = message
    @schema = fetch_schema(@plugin_name)
    render :new, status: :unprocessable_entity
  rescue Kong::Client::Error
    # The schema call itself failing on the error-recovery path shouldn't
    # eat the original JSON error -- render without the reference panel.
    @schema = nil
    render :new, status: :unprocessable_entity
  end

  def fetch_schema(name)
    response = current_client.get("/schemas/plugins/#{name}")
    body = response.body
    body.is_a?(String) ? JSON.parse(body) : body
  end

  # `{"name" => plugin_name, "config" => {defaults from the schema}}` --
  # enough to submit unedited for a plugin with no required fields, and a
  # concrete starting shape for one that does.
  def seed_payload(name, schema)
    config_field = Array(schema["fields"]).find { |f| f.key?("config") }
    { "name" => name, "config" => config_field ? extract_defaults(config_field["config"]["fields"]) : {} }
  end

  def extract_defaults(fields)
    Array(fields).each_with_object({}) do |field, acc|
      key, spec = field.first
      acc[key] = spec["default"] if spec.is_a?(Hash) && spec.key?("default")
    end
  end

  def scope_label
    return "global" if @scope_type.blank?

    parent = KongEntity.active.find_by(kong_connection: current_connection, entity_type: @scope_type, kong_id: @scope_kong_id)
    "#{@scope_type}: #{parent&.name || @scope_kong_id&.first(8)}"
  end
end
