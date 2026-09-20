# Browses kong_entities for the session's current connection and proposes
# changes to them, across every entity_type M0-M3 sync into the read-model
# (docs/DESIGN.md section 15). Read path lives entirely against the local
# read-model; only #sync, #update, and #destroy talk to Kong directly.
# #update/#destroy never touch Kong themselves -- they propose a
# Kong::ChangePlan and hand off to ChangePlansController for review+apply.
class EntitiesController < ApplicationController
  include JsonPayloadParsing

  before_action :require_session!
  before_action :set_type, only: :index
  before_action :set_entity, only: %i[show edit update destroy]

  DEFAULT_TYPE = "service"

  def index
    @filters = params.permit(:q, :tags, :sort).to_h.symbolize_keys
    result = Kong::EntityQuery.new(
      connection: current_connection, type: @type, params: query_params
    ).call
    @entities = result[:data]
    @has_more = result[:has_more]
    @next_cursor = result[:next_cursor]
    # "shown" round-trips through the Load more link (see _pagination.html.erb)
    # purely to keep the "N shown" counter honest across Turbo Stream
    # appends -- it's a display accumulator, not a query filter, so
    # Kong::EntityQuery never sees it.
    @shown_count = params[:shown].to_i + @entities.size

    respond_to do |format|
      format.html
      format.turbo_stream do
        # index.turbo_stream.erb *appends* a page of rows, which is only ever
        # right for "Load more". Any other request that merely accepts
        # turbo_stream must get the whole page instead -- Turbo follows the
        # redirect after "Sync now" with the stream Accept header still set,
        # and appending there stacks a second copy of every row onto the list
        # already on screen (one more copy per click).
        paginating? ? render(:index) : render(:index, formats: :html, content_type: "text/html")
      end
    end
  rescue Kong::EntityQuery::InvalidCursor, Kong::EntityQuery::InvalidSort => e
    redirect_to entities_path, alert: e.message
  end

  def show
    @child_groups = child_groups
  end

  def edit
    @payload_json = JSON.pretty_generate(editable_payload)
  end

  def update
    attributes = params[:payload_json].present? ? json_attributes : edit_attributes

    plan = Kong::ChangePlanner.new(
      connection: current_connection, client: current_client, operation: "update",
      entity_type: @entity.entity_type, target_kong_id: @entity.kong_id, attributes: attributes,
      actor_username: current_connection.auth_username, actor_operator: current_operator
    ).call
    redirect_to change_plan_path(plan)
  rescue JsonPayloadParsing::InvalidPayload => e
    # Re-render rather than redirect so the operator's edit survives the
    # round trip -- a redirect would hand back the unedited document and
    # throw away however long they spent in the textarea.
    @payload_json = params[:payload_json]
    @payload_error = e.message
    render :edit, status: :unprocessable_entity
  rescue Kong::ChangeGuardrails::Violation => e
    redirect_to edit_entity_path(@entity), alert: e.message
  rescue Kong::Client::Error => e
    redirect_to edit_entity_path(@entity), alert: "Couldn't read the current state from Kong: #{e.message}"
  end

  def destroy
    plan = Kong::ChangePlanner.new(
      connection: current_connection, client: current_client, operation: "delete",
      entity_type: @entity.entity_type, target_kong_id: @entity.kong_id,
      actor_username: current_connection.auth_username, actor_operator: current_operator
    ).call
    redirect_to change_plan_path(plan)
  rescue Kong::ChangeGuardrails::Violation => e
    redirect_to entity_path(@entity), alert: e.message
  rescue Kong::Client::Error => e
    redirect_to entity_path(@entity), alert: "Couldn't read the current state from Kong: #{e.message}"
  end

  def sync
    result = Kong::EntitySync.sync_connection(connection: current_connection, client: current_client)
    redirect_to entities_path(type: sync_return_type), notice: "Synced #{result.synced_count} entity(s)" +
      (result.removed_count.positive? ? ", removed #{result.removed_count} no longer in Kong." : ".")
  rescue Kong::Client::Error => e
    redirect_to entities_path(type: sync_return_type), alert: "Sync failed: #{e.message}"
  end

  private

  def set_type
    @type = params[:type].presence || DEFAULT_TYPE
    return if Kong::EntityTypes::DEFINITIONS.key?(@type)

    redirect_to entities_path, alert: "Unknown entity type: #{@type.inspect}"
  end

  # #sync has no before_action :set_type (it doesn't query by type), but
  # still needs to send the browser back to whichever tab "Sync now" was
  # clicked from rather than always landing on services.
  def sync_return_type
    type = params[:type].presence || DEFAULT_TYPE
    Kong::EntityTypes::DEFINITIONS.key?(type) ? type : DEFAULT_TYPE
  end

  def set_entity
    @entity = KongEntity.active.where(kong_connection: current_connection).find(params[:id])
  end

  # "Load more" (see _pagination.html.erb) is the only request that wants
  # the append-a-page turbo_stream template, and it is the only one that
  # carries these params.
  def paginating?
    params[:cursor].present? || params[:shown].present?
  end

  # A service's routes and plugins, a route's plugins, or a consumer's
  # credentials and plugins -- docs/DESIGN.md section 15 M3/M4's "child
  # tabs", each its own labeled group rather than one mixed list since
  # service/consumer now have two different kinds of child. {} for any
  # other entity_type (nothing to nest under a credential or a plugin
  # itself in this UI).
  def child_groups
    case @entity.entity_type
    when "service"
      { "Routes" => children_of("route"), "Plugins" => children_of("plugin") }
    when "route"
      { "Plugins" => children_of("plugin") }
    when "consumer"
      { "Credentials" => children_of(%w[keyauth_credential basicauth_credential]), "Plugins" => children_of("plugin") }
    else
      {}
    end
  end

  def children_of(types)
    KongEntity.active.where(kong_connection: current_connection, parent_type: @entity.entity_type,
      parent_kong_id: @entity.kong_id, entity_type: types)
  end

  # The document the JSON editor opens on: fetched live from Kong rather
  # than read from the cache, because a full-document submit built from a
  # stale copy would silently revert a field the operator never touched
  # back to whatever the last sync saw. Redacted (secrets never reach the
  # browser) and stripped of the fields Kong assigns itself.
  #
  # Falls back to the cached copy if Kong is unreachable, flagging it so the
  # page can say the JSON may be stale.
  def editable_payload
    response = current_client.get("#{Kong::EntityTypes.fetch(@entity.entity_type).list_path}/#{@entity.kong_id}")
    body = response.body
    raw = body.is_a?(String) ? JSON.parse(body) : body
    Kong::Redactor.call(@entity.entity_type, raw)[:data].except(*Kong::EntityTypes::KONG_MANAGED_FIELDS)
  rescue Kong::Client::Error
    @payload_stale = true
    @entity.data.except(*Kong::EntityTypes::KONG_MANAGED_FIELDS)
  end

  # The JSON editor's submission. Kong's PATCH is a partial update, so an
  # omitted key keeps its current value -- which is what makes dropping the
  # managed and secret fields safe rather than destructive.
  def json_attributes
    parse_json_payload!(params[:payload_json], entity_type: @entity.entity_type)
  end

  # String keys, not symbol -- Kong::ChangePlanner merges this straight
  # into the entity's live Kong JSON (also string-keyed), so the keys have
  # to match for an edit to actually override anything. `enabled` is only
  # sent for service and plugin, the two types that actually have the
  # field -- Kong's Route, Consumer, and credential schemas have no such
  # field at all, and PATCHing one with `enabled` present is a hard 400
  # schema violation ("unknown field"), confirmed against a real Kong 3.7.
  # A route can only ever be turned off by deleting it or removing it from
  # its service.
  def edit_attributes
    attrs = { "tags" => params[:tags].to_s.split(",").map(&:strip).reject(&:blank?) }
    attrs["enabled"] = ActiveModel::Type::Boolean.new.cast(params[:enabled]) if @entity.entity_type.in?(%w[service plugin])
    attrs
  end

  # The list filter form submits `tags` as one comma-separated text field
  # (AND semantics, matching EntityQuery's `tags=` contract) rather than a
  # multi-value input; tags_any/tags_none are supported by EntityQuery and
  # the REST API but not surfaced in this simple web form.
  def query_params
    permitted = params.permit(:q, :sort, :cursor, :limit, :tags).to_h.symbolize_keys
    permitted[:tags] = permitted[:tags].to_s.split(",").map(&:strip).reject(&:blank?) if permitted[:tags].present?
    permitted
  end
end
