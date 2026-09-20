require "rails_helper"

RSpec.describe "Entities (web)", type: :request do
  let(:connection) { create(:kong_connection, admin_url: "https://kong-admin.test", credential_mode: "session") }

  def sign_in
    stub_request(:get, "https://kong-admin.test/")
      .to_return(status: 200, body: { version: "3.7.0" }.to_json)
    stub_request(:patch, "https://kong-admin.test#{Kong::AccessProbe::PROBE_PATH}")
      .to_return(status: 404, body: { message: "Not found" }.to_json)
    stub_request(:get, "https://kong-admin.test/consumers/alice")
      .to_return(status: 200, body: { tags: [] }.to_json)
    stub_request(:get, "https://kong-admin.test/routes")
      .to_return(status: 200, body: { data: [], offset: nil }.to_json)
    post login_connection_path(connection), params: { username: "alice", password: "pw" }
  end

  it "redirects to the root path when nobody is signed in" do
    get entities_path
    expect(response).to redirect_to(root_path)
  end

  it "lists synced entities for the current connection" do
    sign_in
    create(:kong_entity, kong_connection: connection, name: "payments-api", tags: [ "payment" ])

    get entities_path

    expect(response).to have_http_status(:ok)
    expect(response.body).to include("payments-api")
  end

  it "shows a protected badge for admin-path entities" do
    sign_in
    create(:kong_entity, kong_connection: connection, name: "admin-api", is_admin_path: true)

    get entities_path

    expect(response.body).to include("protected")
  end

  describe "pagination" do
    before do
      sign_in
      6.times { |n| create(:kong_entity, kong_connection: connection, name: "svc-#{n}", kong_updated_at: n.days.ago) }
    end

    it "shows a Load more link carrying the current limit and a cursor when there's another page" do
      get entities_path, params: { limit: 3 }

      expect(response.body).to include("Load more")
      expect(response.body).to include("limit=3")
      expect(response.body).to include("cursor=")
    end

    it "requesting the next page as turbo_stream appends rows instead of replacing the page" do
      get(entities_path, params: { limit: 3 })
      # the href in the rendered link is already percent-encoded; decode it
      # before handing it back in as a param value, or the test client
      # double-encodes it and the signature fails to verify.
      cursor = URI.decode_www_form_component(response.body[/cursor=([^"&]+)/, 1])

      get entities_path, params: { limit: 3, cursor: cursor, shown: 3 }, as: :turbo_stream

      expect(response.media_type).to eq("text/vnd.turbo-stream.html")
      expect(response.body).to include('turbo-stream action="append" target="entities-list"')
      expect(response.body).to include('turbo-stream action="replace" target="entities-pagination"')
      expect(response.body).to include('turbo-stream action="replace" target="entities-count"')
    end

    it "the turbo_stream response's own Load more link keeps the running shown count, not just the new page's" do
      get entities_path, params: { limit: 3, shown: 3 }, as: :turbo_stream

      expect(response.body).to include("6 services shown")
    end

    # Turbo follows the redirect after a form POST ("Sync now") with the
    # turbo-stream Accept header still set. Serving the append template
    # there stacked a second copy of every row onto the list already on
    # screen -- one more copy per click.
    it "serves the whole page, not an append, to a turbo_stream request carrying no pagination params" do
      get entities_path, as: :turbo_stream

      expect(response.media_type).to eq("text/html")
      expect(response.body).not_to include("turbo-stream action=\"append\"")
      expect(response.body).to include("<html")
    end
  end

  it "syncs from Kong on demand" do
    sign_in
    stub_request(:get, "https://kong-admin.test/services")
      .with(query: { size: "100" })
      .to_return(status: 200, body: { data: [ { id: "11111111-1111-1111-1111-111111111111", name: "one" } ], offset: nil }.to_json)
    stub_request(:get, "https://kong-admin.test/consumers")
      .with(query: { size: "100" })
      .to_return(status: 200, body: { data: [], offset: nil }.to_json)
    stub_request(:get, "https://kong-admin.test/routes")
      .with(query: { size: "100" })
      .to_return(status: 200, body: { data: [], offset: nil }.to_json)
    stub_request(:get, "https://kong-admin.test/key-auths")
      .with(query: { size: "100" })
      .to_return(status: 200, body: { data: [], offset: nil }.to_json)
    stub_request(:get, "https://kong-admin.test/basic-auths")
      .with(query: { size: "100" })
      .to_return(status: 200, body: { data: [], offset: nil }.to_json)
    stub_request(:get, "https://kong-admin.test/plugins")
      .with(query: { size: "100" })
      .to_return(status: 200, body: { data: [], offset: nil }.to_json)

    post sync_entities_path

    expect(response).to redirect_to(entities_path(type: "service"))
    expect(KongEntity.find_by(kong_id: "11111111-1111-1111-1111-111111111111")).to be_present
  end

  it "returns to the tab Sync now was clicked from, not always services" do
    sign_in
    %w[services consumers routes key-auths basic-auths plugins].each do |path|
      stub_request(:get, "https://kong-admin.test/#{path}")
        .with(query: { size: "100" })
        .to_return(status: 200, body: { data: [], offset: nil }.to_json)
    end

    post sync_entities_path(type: "route")

    expect(response).to redirect_to(entities_path(type: "route"))
  end

  it "falls back to services if Sync now somehow posts an unknown type" do
    sign_in
    %w[services consumers routes key-auths basic-auths plugins].each do |path|
      stub_request(:get, "https://kong-admin.test/#{path}")
        .with(query: { size: "100" })
        .to_return(status: 200, body: { data: [], offset: nil }.to_json)
    end

    post sync_entities_path(type: "upstream")

    expect(response).to redirect_to(entities_path(type: "service"))
  end

  it "shows an entity's detail page" do
    sign_in
    entity = create(:kong_entity, kong_connection: connection, name: "payments-api", data: { "host" => "backend.internal" })

    get entity_path(entity)

    expect(response).to have_http_status(:ok)
    expect(response.body).to include("payments-api")
    expect(response.body).to include("backend.internal")
  end

  it "proposes an update and redirects to the change plan for review" do
    sign_in
    entity = create(:kong_entity, kong_connection: connection, kong_id: "44444444-4444-4444-4444-444444444444", name: "payments-api")
    stub_request(:get, "https://kong-admin.test/services/#{entity.kong_id}")
      .to_return(status: 200, body: { id: entity.kong_id, name: "payments-api", tags: [ "payment" ] }.to_json)

    patch entity_path(entity), params: { tags: "payment, deprecated", enabled: "1" }

    expect(response).to redirect_to(change_plan_path(ChangePlan.last))
    expect(ChangePlan.last.diff).to include("tags")
  end

  it "proposes a delete and redirects to the change plan for review" do
    sign_in
    entity = create(:kong_entity, kong_connection: connection, kong_id: "55555555-5555-5555-5555-555555555555", name: "payments-webhook")
    stub_request(:get, "https://kong-admin.test/services/#{entity.kong_id}")
      .to_return(status: 200, body: { id: entity.kong_id, name: "payments-webhook", tags: [] }.to_json)

    delete entity_path(entity)

    expect(response).to redirect_to(change_plan_path(ChangePlan.last))
    expect(ChangePlan.last.operation).to eq("delete")
  end

  describe "entity type switching" do
    it "lists routes instead of services when type=route" do
      sign_in
      create(:kong_entity, kong_connection: connection, entity_type: "service", name: "payments-api")
      create(:kong_entity, kong_connection: connection, entity_type: "route", name: "charge")

      get entities_path(type: "route")

      expect(response.body).to include("charge")
      expect(response.body).not_to include("payments-api")
    end

    it "redirects with an alert for an unknown type" do
      sign_in

      get entities_path(type: "upstream")

      expect(response).to redirect_to(entities_path)
      follow_redirect!
      expect(response.body).to include("Unknown entity type")
    end
  end

  describe "child tabs" do
    it "shows a service's routes on its detail page" do
      sign_in
      service = create(:kong_entity, kong_connection: connection, entity_type: "service", kong_id: "66666666-6666-6666-6666-666666666666", name: "payments-api")
      create(:kong_entity, kong_connection: connection, entity_type: "route", name: "charge", parent_type: "service", parent_kong_id: service.kong_id)

      get entity_path(service)

      expect(response.body).to include("Routes")
      expect(response.body).to include("charge")
    end

    it "shows a consumer's credentials on its detail page" do
      sign_in
      consumer = create(:kong_entity, kong_connection: connection, entity_type: "consumer", kong_id: "77777777-7777-7777-7777-777777777777", name: "alice")
      create(:kong_entity, kong_connection: connection, entity_type: "keyauth_credential", name: "alice/abcd1234", parent_type: "consumer", parent_kong_id: consumer.kong_id)

      get entity_path(consumer)

      expect(response.body).to include("Credentials")
      expect(response.body).to include("alice/abcd1234")
    end
  end

  describe "full-document JSON editing" do
    let(:kong_id) { "aaaaaaa1-1111-1111-1111-111111111111" }

    def stub_live_fetch(body)
      stub_request(:get, "https://kong-admin.test/services/#{kong_id}").to_return(status: 200, body: body.to_json)
    end

    it "opens the editor on the live document from Kong, not the cached copy" do
      sign_in
      create(:kong_entity, kong_connection: connection, kong_id: kong_id, name: "payments-api",
        data: { "name" => "payments-api", "host" => "stale.internal" })
      stub_live_fetch({ id: kong_id, name: "payments-api", host: "live.internal", port: 8080,
                        created_at: 1_700_000_000, updated_at: 1_700_000_000 })

      get edit_entity_path(KongEntity.find_by(kong_id: kong_id))

      expect(response.body).to include("live.internal")
      expect(response.body).not_to include("stale.internal")
      # Kong assigns these itself -- never offered for editing.
      expect(response.body).not_to include("created_at")
    end

    it "falls back to the cached document, flagged as stale, when Kong is unreachable" do
      sign_in
      create(:kong_entity, kong_connection: connection, kong_id: kong_id, name: "payments-api",
        data: { "name" => "payments-api", "host" => "cached.internal" })
      stub_request(:get, "https://kong-admin.test/services/#{kong_id}").to_return(status: 503)

      get edit_entity_path(KongEntity.find_by(kong_id: kong_id))

      expect(response.body).to include("cached.internal")
      expect(response.body).to include("may be out of date")
    end

    it "proposes a plan carrying every edited field, not just tags and enabled" do
      sign_in
      entity = create(:kong_entity, kong_connection: connection, kong_id: kong_id, name: "payments-api")
      stub_live_fetch({ id: kong_id, name: "payments-api", host: "backend.internal", port: 8080,
                        retries: 5, updated_at: 1_700_000_000 })

      patch entity_path(entity), params: {
        payload_json: { name: "payments-api", host: "new-backend.internal", port: 9090, retries: 3 }.to_json
      }

      expect(response).to redirect_to(change_plan_path(ChangePlan.last))
      expect(ChangePlan.last.diff.keys).to contain_exactly("host", "port", "retries")
      expect(ChangePlan.last.after).to include("host" => "new-backend.internal", "port" => 9090, "retries" => 3)
    end

    it "re-renders with the operator's text intact when the JSON doesn't parse" do
      sign_in
      entity = create(:kong_entity, kong_connection: connection, kong_id: kong_id, name: "payments-api")

      patch entity_path(entity), params: { payload_json: '{ "host": "oops",, }' }

      expect(response).to have_http_status(:unprocessable_entity)
      expect(response.body).to include("isn&#39;t valid JSON").or include("isn't valid JSON")
      expect(response.body).to include("oops") # the edit survived the round trip
      expect(ChangePlan.count).to eq(0)
    end

    it "rejects a top-level array with the same treatment" do
      sign_in
      entity = create(:kong_entity, kong_connection: connection, kong_id: kong_id, name: "payments-api")

      patch entity_path(entity), params: { payload_json: '[{"host":"x"}]' }

      expect(response).to have_http_status(:unprocessable_entity)
      expect(response.body).to include("must be an object")
      expect(ChangePlan.count).to eq(0)
    end

    it "strips Kong-assigned fields even if they were left in the document" do
      sign_in
      entity = create(:kong_entity, kong_connection: connection, kong_id: kong_id, name: "payments-api")
      stub_live_fetch({ id: kong_id, name: "payments-api", updated_at: 1_700_000_000 })

      patch entity_path(entity), params: {
        payload_json: { id: "some-other-id", created_at: 1, name: "renamed" }.to_json
      }

      expect(ChangePlan.last.after["id"]).to eq(kong_id)     # from Kong's own copy, not the document
      expect(ChangePlan.last.diff.keys).to contain_exactly("name")
    end

    it "drops a credential secret typed into the editor -- secrets are never settable here" do
      sign_in
      cred_id = "bbbbbbb1-1111-1111-1111-111111111111"
      credential = create(:kong_entity, kong_connection: connection, entity_type: "keyauth_credential",
        kong_id: cred_id, name: "alice/bbbbbbb1")
      stub_request(:get, "https://kong-admin.test/key-auths/#{cred_id}")
        .to_return(status: 200, body: { id: cred_id, key: "super-secret-key-123", tags: [] }.to_json)

      patch entity_path(credential), params: {
        payload_json: { key: "operator-typed-this", tags: [ "rotated" ] }.to_json
      }

      expect(ChangePlan.last.after).not_to have_key("key")
      expect(ChangePlan.last.after["tags"]).to eq([ "rotated" ])
      expect(ChangePlan.last.to_json).not_to include("operator-typed-this")
      expect(ChangePlan.last.to_json).not_to include("super-secret-key-123")
    end
  end

  it "omits the enabled field from a consumer edit -- Kong's Consumer schema has none" do
    sign_in
    consumer = create(:kong_entity, kong_connection: connection, entity_type: "consumer", kong_id: "77777777-7777-7777-7777-777777777777", name: "alice")
    stub_request(:get, "https://kong-admin.test/consumers/#{consumer.kong_id}")
      .to_return(status: 200, body: { id: consumer.kong_id, username: "alice", tags: [] }.to_json)

    patch entity_path(consumer), params: { tags: "vip" }

    expect(ChangePlan.last.after).not_to have_key("enabled")
  end

  # Kong's Route schema has no `enabled` field at all -- confirmed against a
  # real Kong 3.7: PATCHing one with `enabled` present is a hard 400 schema
  # violation ("enabled: unknown field"). Sending it on every tag-only route
  # edit (the bug: routes were lumped in with services) broke every such
  # edit, not just the table's display.
  it "omits the enabled field from a route edit -- Kong's Route schema has none" do
    sign_in
    route = create(:kong_entity, kong_connection: connection, entity_type: "route",
      kong_id: "88888888-8888-8888-8888-888888888888", name: "charge")
    stub_request(:get, "https://kong-admin.test/routes/#{route.kong_id}")
      .to_return(status: 200, body: { id: route.kong_id, name: "charge", tags: [] }.to_json)

    patch entity_path(route), params: { tags: "beta" }

    expect(ChangePlan.last.after).not_to have_key("enabled")
  end

  it "shows no enabled checkbox on a route's edit form" do
    sign_in
    route = create(:kong_entity, kong_connection: connection, entity_type: "route", name: "charge")
    stub_request(:get, "https://kong-admin.test/routes/#{route.kong_id}")
      .to_return(status: 200, body: { id: route.kong_id, name: "charge", tags: [] }.to_json)

    get edit_entity_path(route)

    expect(response.body).not_to include('id="enabled"')
  end

  it "never shows a route as disabled in the table -- Kong has no such concept for routes" do
    sign_in
    create(:kong_entity, kong_connection: connection, entity_type: "route", name: "charge")

    get entities_path(type: "route")

    expect(response.body).not_to include("disabled")
  end

  it "still shows a protected route as protected in the table" do
    sign_in
    connection.update!(admin_path_fingerprint: { "route_ids" => [ "99999999-9999-9999-9999-999999999999" ] })
    create(:kong_entity, kong_connection: connection, entity_type: "route", kong_id: "99999999-9999-9999-9999-999999999999",
      name: "admin-route", is_admin_path: true)

    get entities_path(type: "route")

    expect(response.body).to include("protected")
  end
end
