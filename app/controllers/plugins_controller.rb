# The "Add plugin" web flow -- docs/DESIGN.md section 15 M4, R4. Two steps
# of #new (catalog -> config form) and one #create.
#
# The catalog is what this node loaded (Kong::PluginCatalog): bundled and
# custom apart, each with its description. The config step is a form built
# from the plugin's schema on this connection (Kong::PluginSchemaForm, read
# through Kong::SchemaCache), with a warning when another env of the project
# has a different schema for it (Kong::SchemaMismatch). The scope comes from
# where the flow was entered (a service/route/consumer page, or the Plugins
# tab for a global plugin), or from the scope picker -- which never offers
# an admin-path entity.
#
# The whole-plugin JSON editor stays as "Advanced" (`payload_json`). Either
# way the body goes through Kong::ChangePlanner: a direct env opens the plan
# review, a PR env adds an item to the open changeset (R8), and a PR-mode
# secret must be a reference (Kong::PluginSecretPolicy).
class PluginsController < ApplicationController
  include JsonPayloadParsing

  SCOPE_TYPES = %w[service route consumer].freeze

  before_action :require_session!
  # R1.13: no plugin form where the write would be refused.
  before_action -> { require_writable!(back_to: entities_path(type: "plugin")) }

  def new
    load_scope

    if params[:plugin_name].present?
      load_config_step(params[:plugin_name])
      @payload_json = JSON.pretty_generate(seed_payload(@plugin_name, @schema))
    else
      @catalog = Kong::PluginCatalog.for(current_connection)
    end
  rescue Kong::Client::Error => e
    explain_kong_error(e)
    redirect_to new_plugin_path(scope_type: @scope_type, scope_kong_id: @scope_kong_id),
      alert: "Couldn't load the plugin schema from Kong: #{e.message}"
  end

  def create
    load_scope
    params[:payload_json].present? ? create_from_json : create_from_form
  rescue Kong::ChangeGuardrails::Violation => e
    redirect_to new_plugin_path(scope_type: @scope_type, scope_kong_id: @scope_kong_id), alert: e.message
  rescue Kong::Client::Error => e
    explain_kong_error(e)
    redirect_to new_plugin_path(scope_type: @scope_type, scope_kong_id: @scope_kong_id),
      alert: explain_error(e).title
  end

  private

  def create_from_json
    attributes = parse_json_payload!(params[:payload_json], entity_type: "plugin")
    propose(attributes)
  rescue JsonPayloadParsing::InvalidPayload => e
    render_config_step_with_error(e.message)
  end

  def create_from_form
    load_config_step(params[:plugin_name])
    attributes, @field_errors = Kong::PluginFormParams.call(fields: @fields, params: plugin_params)
    return render_config_step(status: :unprocessable_entity) if @field_errors.any?

    propose(attributes.merge("name" => @plugin_name))
  rescue Kong::ChangePlanner::InvalidChange => e
    @form_error = e.message
    render_config_step(status: :unprocessable_entity)
  end

  def propose(attributes)
    attributes[@scope_type] = { "id" => @scope_kong_id } if @scope_type.present?

    plan = Kong::ChangePlanner.new(
      connection: current_connection, client: current_client, operation: "create", entity_type: "plugin",
      parent_kong_id: @scope_kong_id, attributes: attributes,
      actor_username: current_connection.auth_username, actor_operator: current_operator
    ).call

    if plan.changeset
      redirect_to changeset_path(plan.changeset), notice: "Added to changeset: create plugin #{plan.entity_label}."
    else
      redirect_to change_plan_path(plan)
    end
  end

  # The scope the flow was entered with, or the picker's one select
  # ("service:<kong_id>", or "global").
  def load_scope
    if params[:scope].present?
      type, kong_id = params[:scope].to_s.split(":", 2)
      @scope_type, @scope_kong_id = SCOPE_TYPES.include?(type) && kong_id.present? ? [ type, kong_id ] : [ nil, nil ]
    else
      @scope_type = params[:scope_type].presence
      @scope_kong_id = params[:scope_kong_id].presence
    end
    @scope_label = scope_label
    @scope_fixed = params[:scope_type].present?
  end

  def load_config_step(name)
    @plugin_name = name
    @schema = Kong::SchemaCache.fetch(connection: current_connection, client: current_client, kind: "plugin",
      name: name, strict: true)
    @catalog_entry = Kong::PluginCatalog.for(current_connection).find { |entry| entry.name == name }
    @fields = Kong::PluginSchemaForm.fields(@schema, custom_help: @catalog_entry&.field_help || {})
    @field_errors ||= {}
    @schema_mismatch = Kong::SchemaMismatch.for(connection: current_connection, plugin_name: name)
    @secret_policy = current_connection.apply_mode == "pr" ? :reference_required : :reference_recommended
    @scope_options = scope_options unless @scope_fixed
    @admin_path_scope = current_connection.admin_path?(@scope_kong_id)
  end

  # What was typed, for the re-rendered form -- never a secret field's value.
  def render_config_step(status:)
    secret_names = @fields.select(&:secret).map(&:name)
    @values = plugin_params.fetch("config", {}).to_h.except(*secret_names)
    @payload_json = JSON.pretty_generate(seed_payload(@plugin_name, @schema))
    render :new, status: status
  end

  def plugin_params
    raw = params[:plugin]
    raw.respond_to?(:to_unsafe_h) ? raw.to_unsafe_h : {}
  end

  # R3: the cause and next step behind the alert (Kong::ErrorExplanation).
  def explain_kong_error(error)
    flash[:error_explanation] = explain_error(error).to_flash
  end

  # Re-renders the config step (not a redirect) so the operator's edit
  # survives the round trip, same contract as EntitiesController#update's
  # JSON branch.
  def render_config_step_with_error(message)
    @payload_error = message
    begin
      load_config_step(params[:plugin_name])
    rescue Kong::Client::Error, JSON::ParserError
      # The schema call itself failing on the error-recovery path shouldn't
      # eat the original JSON error -- render without the form fields.
      @schema = nil
      @fields = []
      @field_errors = {}
      @schema_mismatch = []
    end
    @payload_json = params[:payload_json]
    render :new, status: :unprocessable_entity
  end

  # `{"name" => plugin_name, "config" => {defaults from the schema}}` --
  # enough to submit unedited for a plugin with no required fields, and a
  # concrete starting shape for one that does.
  def seed_payload(name, schema)
    config_field = Array(schema && schema["fields"]).find { |f| f.key?("config") }
    { "name" => name, "config" => config_field ? extract_defaults(config_field["config"]["fields"]) : {} }
  end

  def extract_defaults(fields)
    Array(fields).each_with_object({}) do |field, acc|
      key, spec = field.first
      acc[key] = spec["default"] if spec.is_a?(Hash) && spec.key?("default")
    end
  end

  # Services, routes and consumers from the read-model, never an admin-path
  # one: a plugin there is read-only (CLAUDE.md rule 3).
  def scope_options
    KongEntity.active
      .where(kong_connection: current_connection, entity_type: SCOPE_TYPES, is_admin_path: false)
      .order(:entity_type, :name)
      .pluck(:entity_type, :name, :kong_id)
      .reject { |_type, _name, kong_id| current_connection.admin_path?(kong_id) }
      .group_by(&:first)
      .transform_values { |rows| rows.map { |_type, name, kong_id| [ name.presence || kong_id.first(8), kong_id ] } }
  end

  def scope_label
    return "global" if @scope_type.blank?

    parent = KongEntity.active.find_by(kong_connection: current_connection, entity_type: @scope_type, kong_id: @scope_kong_id)
    "#{@scope_type}: #{parent&.name || @scope_kong_id&.first(8)}"
  end
end
