# Browses kong_entities for the session's current connection and proposes
# changes to them, across every entity_type synced into the read-model
# (docs/DESIGN.md section 15). Read path lives entirely against the local
# read-model; only #sync, #update, and #destroy talk to Kong directly.
# #update/#destroy never touch Kong themselves -- they propose a
# Kong::ChangePlan and hand off to ChangePlansController for review+apply.
class EntitiesController < ApplicationController
  include JsonPayloadParsing

  before_action :require_session!
  before_action :set_type, only: :index
  before_action :set_entity, only: %i[show edit update destroy]
  before_action :set_creatable_type, :set_parent, only: %i[new create]

  DEFAULT_TYPE = "service"

  # The types this controller has a "New" flow for (docs/DESIGN.md section 15
  # M5). Everything else is created through PluginsController or the API/MCP.
  CREATABLE_TYPES = %w[upstream target certificate ca_certificate sni].freeze
  TARGET_SEED = { "target" => "", "weight" => 100, "tags" => [] }.freeze
  # The certificate seed's key is *deliberately* an invalid reference (upper
  # case fails Kong::CertificateKeyPolicy): submitted unedited it is refused,
  # rather than creating a certificate pointing at a variable nobody set.
  CERTIFICATE_SEED = {
    "cert" => "-----BEGIN CERTIFICATE-----\n...\n-----END CERTIFICATE-----\n",
    "key" => "{vault://env/cert-NAME-key}",
    "snis" => [],
    "tags" => []
  }.freeze
  CA_CERTIFICATE_SEED = { "cert" => "-----BEGIN CERTIFICATE-----\n...\n-----END CERTIFICATE-----\n", "tags" => [] }.freeze
  SNI_SEED = { "name" => "", "tags" => [] }.freeze
  # What a key reference looks like, ignoring case: the seeded NAME placeholder
  # has this shape (so it may stay on screen) yet is not key material.
  REFERENCE_SHAPE = %r{\A\{vault://env/[a-z0-9][a-z0-9_-]*\}\z}i
  KEY_MATERIAL_REMOVED = "[private key removed]".freeze

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
    # The oldest row, not the newest: a full sync touches every active row, while
    # the write-through after an apply touches one, so the minimum is the last
    # full sync and the maximum would hide how stale the rest is.
    @synced_at = KongEntity.active.where(kong_connection: current_connection).minimum(:synced_at)

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

  def new
    @payload_json = JSON.pretty_generate(seed_payload)
  end

  # Same document editor and review pipeline as an edit: the parsed JSON goes
  # to Kong::ChangePlanner, which validates it against Kong's own schema. A
  # rejection re-renders the form rather than redirecting, so a long
  # healthchecks block isn't lost to a typo.
  def create
    attributes = parse_json_payload!(params[:payload_json], entity_type: @creatable_type)

    plan = Kong::ChangePlanner.new(
      connection: current_connection, client: current_client, operation: "create",
      entity_type: @creatable_type, parent_kong_id: @parent&.kong_id, attributes: attributes,
      actor_username: current_connection.auth_username, actor_operator: current_operator
    ).call
    redirect_to change_plan_path(plan)
  rescue JsonPayloadParsing::InvalidPayload, Kong::ChangeGuardrails::Violation => e
    render_new_with_error(e.message)
  rescue Kong::Client::Error => e
    render_new_with_error("Kong rejected this request: #{e.message}")
  end

  def edit
    @payload_json = JSON.pretty_generate(editable_payload)
  end

  def update
    attributes = params[:payload_json].present? ? json_attributes : edit_attributes

    plan = Kong::ChangePlanner.new(
      connection: current_connection, client: current_client, operation: "update",
      entity_type: @entity.entity_type, target_kong_id: @entity.kong_id, parent_kong_id: @entity.parent_kong_id,
      attributes: attributes, actor_username: current_connection.auth_username, actor_operator: current_operator
    ).call
    redirect_to change_plan_path(plan)
  rescue JsonPayloadParsing::InvalidPayload => e
    # Re-render rather than redirect so the operator's edit survives the
    # round trip -- a redirect would hand back the unedited document and
    # throw away however long they spent in the textarea.
    @payload_json = echoed_payload(@entity.entity_type) { editable_payload }
    @payload_error = safe_message(e.message)
    render :edit, status: :unprocessable_entity
  rescue Kong::ChangePlanner::SchemaViolation, Kong::CertificateKeyPolicy::Rejected => e
    return redirect_to(edit_entity_path(@entity), alert: safe_message(e.message)) if params[:payload_json].blank?

    # Kong refused the document itself: keep the operator's JSON on screen
    # with Kong's per-field message, same as an unparseable payload.
    @payload_json = echoed_payload(@entity.entity_type) { editable_payload }
    @payload_error = safe_message(e.message)
    render :edit, status: :unprocessable_entity
  rescue Kong::ChangeGuardrails::Violation => e
    redirect_to edit_entity_path(@entity), alert: safe_message(e.message)
  rescue Kong::Client::Error => e
    redirect_to edit_entity_path(@entity), alert: "Couldn't read the current state from Kong: #{e.message}"
  end

  def destroy
    plan = Kong::ChangePlanner.new(
      connection: current_connection, client: current_client, operation: "delete",
      entity_type: @entity.entity_type, target_kong_id: @entity.kong_id, parent_kong_id: @entity.parent_kong_id,
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

  def set_creatable_type
    @creatable_type = params[:type].to_s
    return if CREATABLE_TYPES.include?(@creatable_type)

    redirect_to entities_path, alert: "There's no create form for #{@creatable_type.presence&.inspect || 'that type'} here."
  end

  # A nested type (target) is always created inside a parent the operator was
  # already looking at -- no free-text picker, same as PluginsController's
  # scope. An unknown parent bounces back to the list to pick one.
  def set_parent
    definition = Kong::EntityTypes.fetch(@creatable_type)
    return unless definition.requires_parent?

    @parent = KongEntity.active.find_by(
      kong_connection: current_connection, entity_type: definition.parent_type, kong_id: params[:parent_kong_id]
    )
    return if @parent

    redirect_to entities_path(type: definition.parent_type),
      alert: "Pick the #{definition.parent_type} to add this #{@creatable_type} to first."
  end

  def seed_payload
    case @creatable_type
    when "upstream" then Kong::UpstreamPresets.seed(params[:preset])
    when "target" then TARGET_SEED.deep_dup
    when "certificate" then CERTIFICATE_SEED.deep_dup
    when "ca_certificate" then CA_CERTIFICATE_SEED.deep_dup
    when "sni" then SNI_SEED.deep_dup
    end
  end

  # The text an error page puts back in the editor. A private key someone
  # pasted must not round-trip through our HTML. A marker scrub alone misses a
  # key pasted without its BEGIN line, so for the certificate types:
  #   * JSON objects have every key / key_alt value that is not a key
  #     *reference* blanked;
  #   * anything else (unparseable text, or JSON that is not an object) is not
  #     echoed at all -- a textual blanker cannot be made safe -- and the
  #     fallback (the seed, or the live document) is shown instead.
  # Other types keep the operator's text, scrubbed of PEM blocks.
  def echoed_payload(entity_type)
    text = params[:payload_json].to_s
    return Kong::CertificateKeyPolicy.scrub(text) unless entity_type.to_s.in?(Kong::CertificateKeyPolicy::DEEP_SCAN_TYPES)

    parsed = begin
      JSON.parse(text)
    rescue JSON::ParserError
      nil
    end
    return JSON.pretty_generate(blank_key_material(parsed)) if parsed.is_a?(Hash) && !key_material_in_names?(parsed)

    @payload_withheld = true
    JSON.pretty_generate(yield)
  end

  # A field *name* can carry key material too (the policy's deep scan treats it
  # so), and names are not rewritten here: such a document is withheld whole.
  def key_material_in_names?(node)
    case node
    when Hash
      node.any? { |name, value| Kong::CertificateKeyPolicy.scrub(name) != name.to_s || key_material_in_names?(value) }
    when Array then node.any? { |value| key_material_in_names?(value) }
    else false
    end
  end

  # Kong's and the planner's messages can quote the document they refused.
  def safe_message(message)
    Kong::CertificateKeyPolicy.scrub(message)
  end

  def blank_key_material(node)
    case node
    when Hash
      node.to_h do |field, value|
        blank = Kong::CertificateKeyPolicy::KEY_FIELDS.include?(field) && !value.nil? && !key_reference_shaped?(value)
        [ field, blank ? blank_key_value(value) : blank_key_material(value) ]
      end
    when Array then node.map { |value| blank_key_material(value) }
    when String then Kong::CertificateKeyPolicy.scrub(node)
    else node
    end
  end

  # A whole-value PEM shows as the removal notice (so the operator sees why it
  # went); anything else that is not a reference is simply emptied.
  def blank_key_value(value)
    value.is_a?(String) && Kong::CertificateKeyPolicy.scrub(value).strip == KEY_MATERIAL_REMOVED ? KEY_MATERIAL_REMOVED : ""
  end

  # Kong::Redactor::MARK is what a plaintext key Kong holds looks like in the
  # editor; it is not key material and the policy accepts it back, so it must
  # round-trip rather than be emptied.
  def key_reference_shaped?(value)
    return false unless value.is_a?(String)

    value == Kong::Redactor::MARK || Kong::CertificateKeyPolicy.reference?(value) || REFERENCE_SHAPE.match?(value)
  end

  def render_new_with_error(message)
    @payload_json = echoed_payload(@creatable_type) { seed_payload }
    @payload_error = safe_message(message)
    render :new, status: :unprocessable_entity
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
    when "upstream"
      { "Targets" => children_of("target") }
    when "certificate"
      { "SNIs" => children_of("sni") }
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
    path = Kong::EntityTypes.fetch(@entity.entity_type).member_path(@entity.kong_id, parent_kong_id: @entity.parent_kong_id)
    response = current_client.get(path)
    body = response.body
    raw = body.is_a?(String) ? JSON.parse(body) : body
    Kong::Redactor.call(@entity.entity_type, raw)[:data].except(*Kong::EntityTypes::KONG_MANAGED_FIELDS)
  rescue Kong::Client::Error, JSON::ParserError
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
