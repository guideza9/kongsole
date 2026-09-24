require Rails.root.join("spec/support/pem_fixtures")
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

  it "dates the list by its oldest row, so a write-through refresh of one row cannot make the rest look fresh" do
    sign_in
    create(:kong_entity, kong_connection: connection, name: "old-api", synced_at: 3.hours.ago)
    create(:kong_entity, kong_connection: connection, name: "just-applied-api", synced_at: 1.minute.ago)

    get entities_path

    expect(response.body).to include("about 3 hours ago").and include("may be out of date")
  end

  it "says so, rather than dating the list, when the connection has never synced" do
    sign_in

    get entities_path

    expect(response.body).to include("Never synced from #{connection.name}")
  end

  it "marks admin-path entities as the admin path, on the row itself" do
    sign_in
    create(:kong_entity, kong_connection: connection, name: "admin-api", is_admin_path: true)
    create(:kong_entity, kong_connection: connection, name: "payments-api")

    get entities_path

    rows = Nokogiri::HTML(response.body).css(".entity-row:not(.entity-row--head)")
    admin, other = rows.partition { |row| row.text.include?("admin-api") }.map(&:first)
    expect(admin["class"]).to include("entity-row--admin")
    expect(admin.text).to include("admin path")
    expect(other["class"]).not_to include("entity-row--admin")
    expect(other.text).not_to include("admin path")
  end

  it "opens an admin-path entity with what that means for delete and decK" do
    sign_in
    service = create(:kong_entity, kong_connection: connection, name: "admin-api", is_admin_path: true)

    get entity_path(service)

    expect(response.body).to include("This is Kongsole's own way into Kong.")
    expect(response.body).to include("An agent can never delete it").and include("left out of every decK YAML")
  end

  it "says an admin-path plugin is read-only, not deletable" do
    sign_in
    plugin = create(:kong_entity, kong_connection: connection, entity_type: "plugin", name: "basic-auth", is_admin_path: true)

    get entity_path(plugin)

    expect(response.body).to include("guards the admin route").and include("read-only")
    expect(response.body).not_to include("An agent can never delete it")
  end

  describe "Kong-native marks" do
    let(:service_id) { "aaaaaaaa-1111-1111-1111-aaaaaaaaaaaa" }

    it "lists a route as a request line: method chips, host, and a path with its regex marked" do
      sign_in
      create(:kong_entity, kong_connection: connection, entity_type: "route", name: "orders",
        data: { "methods" => %w[GET POST], "hosts" => [ "api.example.com" ], "paths" => [ "/orders", "~/orders/\\d+" ] })
      create(:kong_entity, kong_connection: connection, entity_type: "route", name: "anything", data: {})

      get entities_path(type: "route")

      doc = Nokogiri::HTML(response.body)
      orders, anything = %w[orders anything].map { |name| doc.css(".entity-row").find { |row| row.text.include?(name) } }
      expect(orders.css(".route-method").map(&:text)).to eq(%w[GET POST])
      expect(orders.at_css(".route-host").text).to eq("api.example.com")
      expect(orders.css(".route-path").map { |p| p.text.strip }).to eq([ "/orders", "~/orders/\\d+" ])
      expect(orders.css(".route-path__regex").size).to eq(1)
      expect(anything.at_css(".route-method--any").text).to eq("ANY")
      expect(anything.text).to include("every path")
    end

    it "opens a route on what it matches and links the service it forwards to" do
      sign_in
      service = create(:kong_entity, kong_connection: connection, name: "orders-svc", kong_id: service_id)
      route = create(:kong_entity, kong_connection: connection, entity_type: "route", name: "orders",
        data: { "methods" => [ "GET" ], "paths" => [ "/orders" ], "service" => { "id" => service_id }, "strip_path" => false, "protocols" => %w[https] })

      get entity_path(route)

      doc = Nokogiri::HTML(response.body)
      panel = doc.at_css("section[aria-labelledby='route-match-heading']")
      expect(panel.at_css(".route-method").text).to eq("GET")
      expect(panel.at_css("a")["href"]).to eq(entity_path(service))
      expect(panel.text).to include("keeps the matched path").and include("https")
    end

    it "says so when a route's service has not been synced" do
      sign_in
      route = create(:kong_entity, kong_connection: connection, entity_type: "route", name: "orders",
        data: { "service" => { "id" => "ffffffff-0000-0000-0000-ffffffffffff" } })

      get entity_path(route)

      expect(response.body).to include("a service that has not been synced yet")
    end

    it "shows a global plugin as the solid Global mark and a scoped one as kind plus name" do
      sign_in
      svc = create(:kong_entity, kong_connection: connection, name: "checkout", kong_id: service_id)
      create(:kong_entity, kong_connection: connection, entity_type: "plugin", name: "cors")
      create(:kong_entity, kong_connection: connection, entity_type: "plugin", name: "key-auth",
        parent_type: "service", parent_kong_id: svc.kong_id)

      get entities_path(type: "plugin")

      doc = Nokogiri::HTML(response.body)
      cors, key_auth = %w[cors key-auth].map { |name| doc.css(".entity-row").find { |row| row.text.include?(name) } }
      expect(cors.at_css(".scope--global .scope__kind").text).to eq("Global")
      expect(key_auth.at_css(".scope__kind").text).to eq("service")
      expect(key_auth.at_css(".scope__name").text).to eq("checkout")
      expect(key_auth.at_css(".scope--global")).to be_nil
    end

    it "opens a plugin on its scope, in a sentence, with a link to what it is attached to" do
      sign_in
      route = create(:kong_entity, kong_connection: connection, entity_type: "route", name: "orders", kong_id: service_id)
      plugin = create(:kong_entity, kong_connection: connection, entity_type: "plugin", name: "rate-limiting",
        parent_type: "route", parent_kong_id: route.kong_id)

      get entity_path(plugin)

      panel = Nokogiri::HTML(response.body).at_css("section[aria-labelledby='plugin-scope-heading']")
      expect(panel.text).to include("Runs on requests that match this route.")
      expect(panel.at_css("a")["href"]).to eq(entity_path(route))
    end

    it "lists the hostnames a certificate answers for under its name" do
      sign_in
      create(:kong_entity, kong_connection: connection, entity_type: "certificate", name: "cert-1", not_after: 90.days.from_now,
        data: { "snis" => %w[x.example], "_metadata" => { "sans" => %w[a.example b.example c.example d.example] } })

      get entities_path(type: "certificate")

      expect(response.body).to include("a.example, b.example +2")
    end

    it "draws a certificate's lifespan on its page, toned like its expiry badge" do
      sign_in
      certificate = create(:kong_entity, kong_connection: connection, entity_type: "certificate", name: "cert-1",
        not_after: 10.days.from_now,
        data: { "_metadata" => { "not_before" => 90.days.ago.utc.iso8601, "not_after" => 10.days.from_now.utc.iso8601 } })

      get entity_path(certificate)

      bar = Nokogiri::HTML(response.body).at_css(".lifespan")
      expect(bar["class"]).to include("lifespan--warning")
      expect(bar["aria-label"]).to match(/\A9\d% of this certificate's validity has passed\z/)
    end
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
      # update, not replace: #entities-count is a persistent live region.
      expect(response.body).to include('turbo-stream action="update" target="entities-count"')
      expect(response.body).not_to include('turbo-stream action="replace" target="entities-count"')
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
    stub_request(:get, "https://kong-admin.test/upstreams")
      .with(query: { size: "100" })
      .to_return(status: 200, body: { data: [], offset: nil }.to_json)
    stub_request(:get, "https://kong-admin.test/certificates")
      .with(query: { size: "100" })
      .to_return(status: 200, body: { data: [], offset: nil }.to_json)
    stub_request(:get, "https://kong-admin.test/snis")
      .with(query: { size: "100" })
      .to_return(status: 200, body: { data: [], offset: nil }.to_json)
    stub_request(:get, "https://kong-admin.test/ca_certificates")
      .with(query: { size: "100" })
      .to_return(status: 200, body: { data: [], offset: nil }.to_json)

    post sync_entities_path

    expect(response).to redirect_to(entities_path(type: "service"))
    expect(KongEntity.find_by(kong_id: "11111111-1111-1111-1111-111111111111")).to be_present
  end

  it "returns to the tab Sync now was clicked from, not always services" do
    sign_in
    %w[services consumers routes key-auths basic-auths plugins upstreams certificates snis ca_certificates].each do |path|
      stub_request(:get, "https://kong-admin.test/#{path}")
        .with(query: { size: "100" })
        .to_return(status: 200, body: { data: [], offset: nil }.to_json)
    end

    post sync_entities_path(type: "route")

    expect(response).to redirect_to(entities_path(type: "route"))
  end

  it "falls back to services if Sync now somehow posts an unknown type" do
    sign_in
    %w[services consumers routes key-auths basic-auths plugins upstreams certificates snis ca_certificates].each do |path|
      stub_request(:get, "https://kong-admin.test/#{path}")
        .with(query: { size: "100" })
        .to_return(status: 200, body: { data: [], offset: nil }.to_json)
    end

    post sync_entities_path(type: "widget")

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

  it "explains a Kong refusal behind the alert, by its own cause (R3)" do
    sign_in
    entity = create(:kong_entity, kong_connection: connection, kong_id: "46464646-4646-4646-4646-464646464646", name: "payments-api")
    stub_request(:get, "https://kong-admin.test/services/#{entity.kong_id}")
      .to_return(status: 404, body: { message: "no Route matched with those values" }.to_json)

    patch entity_path(entity), params: { tags: "payment", enabled: "1" }

    expect(response).to redirect_to(edit_entity_path(entity))
    expect(flash[:alert]).to be_present
    expect(flash[:error_explanation]["key"]).to eq("route_not_matched")
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

      get entities_path(type: "widget")

      expect(response).to redirect_to(entities_path)
      follow_redirect!
      expect(response.body).to include("Unknown entity type")
    end
  end

  describe "one filled primary action per list page" do
    def primary_texts
      Nokogiri::HTML(response.body).css(".btn-primary").map { |node| node.text.strip }
    end

    it "makes only 'New upstream' primary on the upstreams list; Filter is secondary" do
      sign_in

      get entities_path(type: "upstream")

      expect(primary_texts).to eq([ "New upstream" ])
      filter = Nokogiri::HTML(response.body).css("button[type=submit]").find { |node| node.text.strip == "Filter" }
      expect(filter["class"].split).to include("btn", "btn-secondary")
      expect(filter["class"].split).not_to include("btn-primary")
    end

    it "renders at most one filled primary on the services list" do
      sign_in

      get entities_path(type: "service")

      expect(primary_texts.size).to be <= 1
    end

    it "gives header actions the shared .btn sizing rather than per-view padding" do
      sign_in

      get entities_path(type: "upstream")

      new_link = Nokogiri::HTML(response.body).css("a.btn-primary").first
      expect(new_link["class"].split).to include("btn")
      expect(new_link["class"]).not_to match(/\bp[xy]-\d/)
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

  describe "upstreams and targets (M5a)" do
    let(:upstream_id) { "aaaaaaaa-0000-0000-0000-00000000000a" }
    let(:target_id) { "cccccccc-0000-0000-0000-00000000000c" }
    let(:ok) { { status: 200, body: { message: "schema validation successful" }.to_json } }

    def create_upstream(name: "orders", **attrs)
      create(:kong_entity, kong_connection: connection, entity_type: "upstream", kong_id: upstream_id, name: name,
        data: { "name" => name, "algorithm" => "round-robin" }, **attrs)
    end

    def create_target(**attrs)
      create(:kong_entity, kong_connection: connection, entity_type: "target", kong_id: target_id, name: "10.0.0.1:8080",
        parent_type: "upstream", parent_kong_id: upstream_id, data: { "target" => "10.0.0.1:8080", "weight" => 100 }, **attrs)
    end

    describe "listing" do
      it "has an Upstreams tab and lists upstreams with their algorithm" do
        sign_in
        create_upstream

        get entities_path(type: "upstream")

        expect(response).to have_http_status(:ok)
        expect(response.body).to include("Upstreams")
        expect(response.body).to include("orders")
        expect(response.body).to include("round-robin")
      end

      it "offers a New upstream button only on the upstreams tab" do
        sign_in

        get entities_path(type: "upstream")
        expect(response.body).to include("New upstream")

        get entities_path(type: "service")
        expect(response.body).not_to include("New upstream")
      end

      it "lists targets, showing weight, when asked for type=target directly" do
        sign_in
        create_upstream
        create_target

        get entities_path(type: "target")

        expect(response.body).to include("10.0.0.1:8080")
        expect(response.body).to include("100")
      end
    end

    describe "an upstream's detail page" do
      it "shows its Targets, with an Add target link carrying the upstream" do
        sign_in
        upstream = create_upstream
        create_target

        get entity_path(upstream)

        expect(response.body).to include("Targets")
        expect(response.body).to include("10.0.0.1:8080")
        expect(response.body).to include(new_entity_path(type: "target", parent_kong_id: upstream_id).gsub("&", "&amp;"))
      end

      it "does not label targets (or any child with no `enabled` field) as disabled" do
        sign_in
        upstream = create_upstream
        create_target(enabled: nil)

        get entity_path(upstream)

        expect(response.body).not_to include(">disabled<")
      end

      it "still labels a child that Kong reports as explicitly disabled" do
        sign_in
        service = create(:kong_entity, kong_connection: connection, entity_type: "service", kong_id: "66666666-6666-6666-6666-666666666666", name: "payments-api")
        create(:kong_entity, kong_connection: connection, entity_type: "plugin", name: "cors", enabled: false,
          parent_type: "service", parent_kong_id: service.kong_id)

        get entity_path(service)

        expect(response.body).to include(">disabled<")
      end
    end

    describe "GET /entities/new" do
      it "opens an upstream form seeded with sensible defaults" do
        sign_in

        get new_entity_path(type: "upstream")

        expect(response).to have_http_status(:ok)
        expect(response.body).to include("New upstream")
        expect(response.body).to include("&quot;algorithm&quot;: &quot;round-robin&quot;")
        expect(response.body).not_to include("healthchecks")
      end

      it "offers a preset that seeds an active HTTP health check" do
        sign_in

        get new_entity_path(type: "upstream", preset: "active_http")

        expect(response.body).to include("&quot;healthchecks&quot;")
        expect(response.body).to include("&quot;http_path&quot;: &quot;/health&quot;")
        expect(response.body).to include("Start from")
      end

      it "ignores an unknown preset rather than erroring" do
        sign_in

        get new_entity_path(type: "upstream", preset: "nope")

        expect(response).to have_http_status(:ok)
        expect(response.body).not_to include("healthchecks")
      end

      it "opens a target form scoped to its upstream" do
        sign_in
        create_upstream

        get new_entity_path(type: "target", parent_kong_id: upstream_id)

        expect(response).to have_http_status(:ok)
        expect(response.body).to include("upstream: orders")
        expect(response.body).to include("&quot;weight&quot;: 100")
      end

      it "redirects a target form with no known upstream" do
        sign_in

        get new_entity_path(type: "target", parent_kong_id: upstream_id)

        expect(response).to redirect_to(entities_path(type: "upstream"))
        follow_redirect!
        expect(response.body).to include("upstream")
      end

      it "only opens forms for types the UI can create, not e.g. a service" do
        sign_in

        get new_entity_path(type: "service")

        expect(response).to redirect_to(entities_path)
      end
    end

    describe "POST /entities (create)" do
      it "proposes an upstream, validated against Kong's schema, and redirects to review" do
        sign_in
        validate = stub_request(:post, "https://kong-admin.test/schemas/upstreams/validate").to_return(ok)

        post entities_path, params: { type: "upstream", payload_json: { name: "orders", algorithm: "round-robin" }.to_json }

        plan = ChangePlan.last
        expect(response).to redirect_to(change_plan_path(plan))
        expect(plan.entity_type).to eq("upstream")
        expect(plan.operation).to eq("create")
        expect(plan.after).to eq({ "name" => "orders", "algorithm" => "round-robin" })
        expect(validate).to have_been_requested
      end

      it "proposes a target under its upstream" do
        sign_in
        create_upstream
        stub_request(:post, "https://kong-admin.test/schemas/targets/validate").to_return(ok)

        post entities_path, params: { type: "target", parent_kong_id: upstream_id,
                                      payload_json: { target: "10.0.0.1:8080", weight: 100 }.to_json }

        plan = ChangePlan.last
        expect(response).to redirect_to(change_plan_path(plan))
        expect(plan.entity_type).to eq("target")
        expect(plan.parent_kong_id).to eq(upstream_id)
      end

      it "strips Kong-assigned fields left in the document" do
        sign_in
        stub_request(:post, "https://kong-admin.test/schemas/upstreams/validate").to_return(ok)

        post entities_path, params: { type: "upstream", payload_json: { id: "x", name: "orders", created_at: 1 }.to_json }

        expect(ChangePlan.last.after).to eq({ "name" => "orders" })
      end

      it "re-renders with the operator's text and Kong's field errors when the schema rejects it, creating no plan" do
        sign_in
        stub_request(:post, "https://kong-admin.test/schemas/upstreams/validate").to_return(
          status: 400, body: { name: "schema violation", message: "schema violation",
                               fields: { healthchecks: { active: { http_path: "should start with: /" } } } }.to_json
        )
        payload = { name: "orders", healthchecks: { active: { http_path: "health" } } }.to_json

        post entities_path, params: { type: "upstream", payload_json: payload }

        expect(response).to have_http_status(:unprocessable_entity)
        expect(response.body).to include("healthchecks.active.http_path: should start with: /")
        expect(response.body).to include("health&quot;") # the edit survives the round trip
        expect(ChangePlan.count).to eq(0)
      end

      it "re-renders with the text intact when the JSON doesn't parse" do
        sign_in

        post entities_path, params: { type: "upstream", payload_json: "{ not json" }

        expect(response).to have_http_status(:unprocessable_entity)
        expect(response.body).to include("valid JSON")
        expect(response.body).to include("{ not json")
      end

      it "refuses a type the UI can't create" do
        sign_in

        post entities_path, params: { type: "service", payload_json: { name: "x" }.to_json }

        expect(response).to redirect_to(entities_path)
        expect(ChangePlan.count).to eq(0)
      end

      it "refuses to propose on a read-only credential" do
        sign_in
        connection.update!(access_level: "ro")

        post entities_path, params: { type: "upstream", payload_json: { name: "orders" }.to_json }

        expect(response).to have_http_status(:unprocessable_entity)
        expect(response.body).to match(/can(&#39;|')t write/)
        expect(ChangePlan.count).to eq(0)
      end
    end

    describe "editing a target" do
      let(:member_url) { "https://kong-admin.test/upstreams/#{upstream_id}/targets/#{target_id}" }

      it "opens the editor on the live target, fetched through its upstream" do
        sign_in
        target = create_target
        get_live = stub_request(:get, member_url).to_return(status: 200, body: {
          id: target_id, target: "10.0.0.1:8080", weight: 77, upstream: { id: upstream_id },
          created_at: 1_700_000_000.226, updated_at: 1_700_000_000.5
        }.to_json)

        get edit_entity_path(target)

        expect(get_live).to have_been_requested
        expect(response.body).to include("&quot;weight&quot;: 77")
        expect(response.body).not_to include("created_at")
      end

      it "proposes a weight change, resolving the upstream from the read-model" do
        sign_in
        target = create_target
        stub_request(:get, member_url).to_return(status: 200, body: {
          id: target_id, target: "10.0.0.1:8080", weight: 100, upstream: { id: upstream_id }, updated_at: 1_700_000_000.5
        }.to_json)
        stub_request(:post, "https://kong-admin.test/schemas/targets/validate").to_return(ok)

        patch entity_path(target), params: { payload_json: { weight: 50 }.to_json }

        plan = ChangePlan.last
        expect(response).to redirect_to(change_plan_path(plan))
        expect(plan.parent_kong_id).to eq(upstream_id)
        expect(plan.diff).to eq({ "weight" => { "from" => 100, "to" => 50 } })
      end

      it "re-renders the editor with Kong's message, keeping the operator's JSON, on a schema rejection" do
        sign_in
        upstream = create_upstream
        stub_request(:get, "https://kong-admin.test/upstreams/#{upstream_id}").to_return(status: 200, body: {
          id: upstream_id, name: "orders", algorithm: "round-robin", updated_at: 1_700_000_000
        }.to_json)
        stub_request(:post, "https://kong-admin.test/schemas/upstreams/validate").to_return(
          status: 400, body: { message: "schema violation", fields: { algorithm: "expected one of: round-robin, consistent-hashing" } }.to_json
        )

        patch entity_path(upstream), params: { payload_json: { algorithm: "bogus" }.to_json }

        expect(response).to have_http_status(:unprocessable_entity)
        expect(response.body).to include("algorithm: expected one of")
        expect(response.body).to include("bogus")
        expect(ChangePlan.count).to eq(0)
      end

      it "proposes deleting a target through its upstream" do
        sign_in
        target = create_target
        stub_request(:get, member_url).to_return(status: 200, body: {
          id: target_id, target: "10.0.0.1:8080", weight: 100, upstream: { id: upstream_id }, updated_at: 1_700_000_000.5
        }.to_json)

        delete entity_path(target)

        plan = ChangePlan.last
        expect(response).to redirect_to(change_plan_path(plan))
        expect(plan.operation).to eq("delete")
        expect(plan.parent_kong_id).to eq(upstream_id)
      end
    end

    describe "syncing" do
      it "syncs upstreams and their targets from the Sync now button" do
        sign_in
        %w[services consumers key-auths basic-auths plugins certificates snis ca_certificates].each do |path|
          stub_request(:get, "https://kong-admin.test/#{path}").with(query: { size: "100" })
            .to_return(status: 200, body: { data: [], offset: nil }.to_json)
        end
        stub_request(:get, "https://kong-admin.test/routes").with(query: { size: "100" })
          .to_return(status: 200, body: { data: [], offset: nil }.to_json)
        stub_request(:get, "https://kong-admin.test/upstreams").with(query: { size: "100" })
          .to_return(status: 200, body: { data: [ { id: upstream_id, name: "orders", algorithm: "round-robin" } ], offset: nil }.to_json)
        stub_request(:get, "https://kong-admin.test/upstreams/#{upstream_id}/targets").with(query: { size: "100" })
          .to_return(status: 200, body: { data: [ { id: target_id, target: "10.0.0.1:8080", weight: 100, upstream: { id: upstream_id } } ], offset: nil }.to_json)

        post sync_entities_path(type: "upstream")

        expect(response).to redirect_to(entities_path(type: "upstream"))
        expect(KongEntity.active.pluck(:entity_type)).to contain_exactly("upstream", "target")
      end
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

  it "still marks an admin-path route as the admin path in the table" do
    sign_in
    connection.update!(admin_path_fingerprint: { "route_ids" => [ "99999999-9999-9999-9999-999999999999" ] })
    create(:kong_entity, kong_connection: connection, entity_type: "route", kong_id: "99999999-9999-9999-9999-999999999999",
      name: "admin-route", is_admin_path: true)

    get entities_path(type: "route")

    expect(response.body).to include("admin path")
  end

  describe "certificates (M5b)" do
    let(:cert_id) { "dddddddd-0000-0000-0000-00000000000d" }
    let(:sni_id) { "eeeeeeee-0000-0000-0000-00000000000e" }
    let(:metadata) do
      { "subject" => "CN=pay.example.internal,O=Spec", "issuer" => "CN=Spec CA", "serial" => "ABC123",
        "not_before" => 1.day.ago.iso8601, "not_after" => 12.days.from_now.iso8601,
        "fingerprint_sha256" => "a" * 64, "sans" => [ "DNS:pay.example.internal" ] }
    end

    def create_certificate(name: "pay.example.internal", key: "{vault://env/cert-pay-key}", not_after: 12.days.from_now, **attrs)
      create(:kong_entity, kong_connection: connection, entity_type: "certificate", kong_id: cert_id, name: name, not_after: not_after,
        data: { "key" => key, "snis" => [ name ], "_metadata" => metadata }, **attrs)
    end

    it "has Certificates and CA certificates tabs" do
      sign_in

      get entities_path(type: "certificate")

      expect(response.body).to include("Certificates").and include("CA certificates")
    end

    it "lists certificates with an expiry badge and how long is left" do
      sign_in
      create_certificate
      create(:kong_entity, kong_connection: connection, entity_type: "certificate", name: "gone.example", not_after: 2.days.ago,
        data: { "_metadata" => metadata })

      get entities_path(type: "certificate")

      expect(response.body).to include("pay.example.internal").and include("gone.example")
      expect(response.body).to include("Warning") # 12 days left
      expect(response.body).to include("Expired")
      expect(response.body).to include("2 days ago")
    end

    it "shows how many SNIs each certificate has" do
      sign_in
      create(:kong_entity, kong_connection: connection, entity_type: "certificate", name: "multi.example", not_after: 90.days.from_now,
        data: { "snis" => %w[multi.example a.example b.example], "_metadata" => metadata })

      get entities_path(type: "certificate")

      expect(response.body).to include("SNIs") # column header
      expect(response.body).to match(/tabular-nums[^>]*>\s*3\s*</)
    end

    it "lists CA certificates the same way" do
      sign_in
      create(:kong_entity, kong_connection: connection, entity_type: "ca_certificate", name: "9852b7219ac3", not_after: 400.days.from_now,
        data: { "_metadata" => metadata })

      get entities_path(type: "ca_certificate")

      expect(response.body).to include("9852b7219ac3").and include("Ok")
    end

    it "shows a certificate's metadata, and the env var its key reference reads" do
      sign_in
      certificate = create_certificate

      get entity_path(certificate)

      expect(response.body).to include("CN=pay.example.internal,O=Spec").and include("CN=Spec CA")
      expect(response.body).to include("a" * 64)
      expect(response.body).to include("DNS:pay.example.internal")
      expect(response.body).to include("{vault://env/cert-pay-key}")
      expect(response.body).to include("CERT_PAY_KEY")
    end

    it "still renders the detail page when the cached not_before is garbage" do
      sign_in
      certificate = create_certificate
      certificate.update!(data: certificate.data.merge("_metadata" => metadata.merge("not_before" => "not a date")))

      get entity_path(certificate)

      expect(response).to have_http_status(:ok)
      expect(response.body).to include("CN=pay.example.internal,O=Spec")
    end

    it "warns when Kong still holds a plaintext key, since the tool can never have set it" do
      sign_in
      certificate = create_certificate(key: "[REDACTED]")

      get entity_path(certificate)

      expect(response.body).to include("plaintext")
      expect(response.body).not_to include("PRIVATE KEY")
    end

    it "shows the certificate's SNIs with an Add SNI link scoped to it" do
      sign_in
      certificate = create_certificate
      create(:kong_entity, kong_connection: connection, entity_type: "sni", kong_id: sni_id, name: "api.example.internal",
        parent_type: "certificate", parent_kong_id: cert_id, enabled: nil)

      get entity_path(certificate)

      expect(response.body).to include("SNIs").and include("api.example.internal")
      expect(response.body).to include(new_entity_path(type: "sni", parent_kong_id: cert_id).gsub("&", "&amp;"))
      expect(response.body).not_to include(">disabled<")
    end

    it "does not show certificate panels on other entity types" do
      sign_in
      service = create(:kong_entity, kong_connection: connection, entity_type: "service", name: "payments-api")

      get entity_path(service)

      expect(response.body).not_to include("Key reference")
    end

    describe "forms" do
      let(:ok) { { status: 200, body: { message: "schema validation successful" }.to_json } }
      let(:pem) { PemFixtures.self_signed(days: 60) }
      let(:private_key_pem) { pem[:key_pem] }

      it "opens a certificate form seeded with a key placeholder that must be edited, and explains the reference" do
        sign_in

        get new_entity_path(type: "certificate")

        expect(response).to have_http_status(:ok)
        expect(response.body).to include("New certificate")
        expect(response.body).to include("{vault://env/cert-NAME-key}")
        expect(response.body).to include("CERT_PAYMENTS_KEY")
        expect(response.body).to include("can't be pasted") # static template text, not user content, so not HTML-escaped
      end

      it "mentions the decK placeholder only on a PR-mode connection" do
        sign_in
        get new_entity_path(type: "certificate")
        expect(response.body).not_to include("DECK_")

        connection.update!(apply_mode: "pr")
        get new_entity_path(type: "certificate")
        expect(response.body).to include("DECK_")
      end

      it "opens CA certificate and SNI forms" do
        sign_in
        create_certificate

        get new_entity_path(type: "ca_certificate")
        expect(response.body).to include("New CA certificate")
        expect(response.body).not_to include("&quot;key&quot;")

        get new_entity_path(type: "sni", parent_kong_id: cert_id)
        expect(response.body).to include("certificate: pay.example.internal")
      end

      it "sends an SNI form with no known certificate back to the certificate list" do
        sign_in

        get new_entity_path(type: "sni", parent_kong_id: cert_id)

        expect(response).to redirect_to(entities_path(type: "certificate"))
      end

      it "offers New certificate and New CA certificate buttons on their own tabs only" do
        sign_in

        get entities_path(type: "certificate")
        expect(response.body).to include("New certificate")
        get entities_path(type: "ca_certificate")
        expect(response.body).to include("New CA certificate")
        get entities_path(type: "service")
        expect(response.body).not_to include("New certificate")
      end

      it "proposes a certificate whose key is a vault reference" do
        sign_in
        validate = stub_request(:post, "https://kong-admin.test/schemas/certificates/validate").to_return(ok)

        post entities_path, params: { type: "certificate",
          payload_json: { cert: pem[:cert_pem], key: "{vault://env/cert-pay-key}", snis: [ "pay.example.internal" ] }.to_json }

        plan = ChangePlan.last
        expect(response).to redirect_to(change_plan_path(plan))
        expect(plan.entity_type).to eq("certificate")
        expect(plan.after["key"]).to eq("{vault://env/cert-pay-key}")
        expect(validate).to have_been_requested
      end

      it "refuses a pasted private key: 422, a fix in the message, no plan, no Kong call, and the key is not echoed back" do
        sign_in

        post entities_path, params: { type: "certificate", payload_json: { cert: pem[:cert_pem], key: private_key_pem }.to_json }

        expect(response).to have_http_status(:unprocessable_entity)
        expect(response.body).to include("{vault://env/")
        expect(response.body).to include("private key removed")
        expect(response.body).not_to include("PRIVATE KEY")
        expect(response.body).not_to include(private_key_pem.lines[1].strip)
        expect(ChangePlan.count).to eq(0)
        expect(WebMock).not_to have_requested(:post, /schemas/)
      end

      it "refuses the unedited seed, whose NAME placeholder is not a valid reference" do
        sign_in

        post entities_path, params: { type: "certificate",
          payload_json: { cert: pem[:cert_pem], key: "{vault://env/cert-NAME-key}", snis: [], tags: [] }.to_json }

        expect(response).to have_http_status(:unprocessable_entity)
        expect(ChangePlan.count).to eq(0)
      end

      it "refuses a decK placeholder on a direct-mode connection" do
        sign_in

        post entities_path, params: { type: "certificate", payload_json: { cert: pem[:cert_pem], key: '${{ env "DECK_CERT_A" }}' }.to_json }

        expect(response).to have_http_status(:unprocessable_entity)
        expect(response.body).to include("PR mode")
      end

      it "does not echo a private key even when the JSON is malformed" do
        sign_in
        broken = "{ \"key\": \"#{private_key_pem.gsub("\n", '\n')}\" oops"

        post entities_path, params: { type: "certificate", payload_json: broken }

        expect(response).to have_http_status(:unprocessable_entity)
        expect(response.body).not_to include("BEGIN PRIVATE KEY")
        expect(response.body).not_to include(private_key_pem.lines[1].strip)
        expect(response.body).to include("wasn't kept")
        expect(response.body).to include("{vault://env/cert-NAME-key}") # the seed is back
      end

      {
        "an unquoted key name" => '{"cert": "c", key: HEADLESSSENTINEL0123456789}',
        "single quotes" => "{'key': 'HEADLESSSENTINEL0123456789'}",
        "a multi-element array" => '{"key": ["a", "HEADLESSSENTINEL0123456789"',
        "a multi-entry object" => '{"key": {"a": "b", "c": "HEADLESSSENTINEL0123456789"}',
        "a stray inner quote" => '{"key": "abc"HEADLESSSENTINEL0123456789"}',
        "a bare string" => '"HEADLESSSENTINEL0123456789"',
        "a top-level array" => '["HEADLESSSENTINEL0123456789"]'
      }.each do |shape, payload|
        it "withholds unparseable or non-object text instead of echoing it (#{shape})" do
          sign_in

          post entities_path, params: { type: "certificate", payload_json: payload }

          expect(response).to have_http_status(:unprocessable_entity)
          expect(response.body).not_to include("HEADLESSSENTINEL")
          expect(response.body).to include("wasn't kept")
          expect(ChangePlan.count).to eq(0)
        end
      end

      {
        "at the top level" => { "-----BEGIN PRIVATE KEY-----NAMESENTINEL2" => 1, "key" => "{vault://env/cert-x-key}" },
        "inside an snis array" => { "key" => "{vault://env/cert-x-key}", "snis" => [ { "-----BEGIN PRIVATE KEY-----NAMESENTINEL2" => 1 } ] },
        "inside an snis hash" => { "key" => "{vault://env/cert-x-key}", "snis" => { "-----BEGIN PRIVATE KEY-----NAMESENTINEL2" => 1 } }
      }.each do |where, document|
        it "withholds a document with key material in a field name, #{where} (create)" do
          sign_in

          post entities_path, params: { type: "certificate", payload_json: document.to_json }

          expect(response).to have_http_status(:unprocessable_entity)
          expect(response.body).not_to include("NAMESENTINEL2")
          expect(response.body).to include("wasn't kept")
          expect(ChangePlan.count).to eq(0)
        end

        it "withholds a document with key material in a field name, #{where} (update)" do
          sign_in
          certificate = create_certificate
          stub_request(:get, "https://kong-admin.test/certificates/#{cert_id}").to_return(status: 200, body: {
            id: cert_id, cert: pem[:cert_pem], key: "{vault://env/cert-pay-key}", snis: [], tags: [], updated_at: 1_700_000_000
          }.to_json)

          patch entity_path(certificate), params: { payload_json: document.to_json }

          expect(response).to have_http_status(:unprocessable_entity)
          expect(response.body).not_to include("NAMESENTINEL2")
          expect(response.body).to include("wasn't kept")
        end
      end

      it "scrubs a private key block out of Kong's own error message" do
        sign_in
        stub_request(:post, "https://kong-admin.test/schemas/certificates/validate").to_return(
          status: 400, body: { message: "schema violation", fields: { cert: "bad #{private_key_pem}" } }.to_json
        )

        post entities_path, params: { type: "certificate",
          payload_json: { cert: pem[:cert_pem], key: "{vault://env/cert-pay-key}" }.to_json }

        expect(response).to have_http_status(:unprocessable_entity)
        expect(response.body).to include("private key removed")
        expect(response.body).not_to include("BEGIN PRIVATE KEY")
        expect(response.body).not_to include(private_key_pem.lines[1].strip)
      end

      it "falls back to the cached document when Kong answers the editor's fetch with non-JSON" do
        sign_in
        certificate = create_certificate
        stub_request(:get, "https://kong-admin.test/certificates/#{cert_id}").to_return(
          status: 200, body: "<html>proxy error</html>", headers: { "Content-Type" => "text/html" }
        )

        patch entity_path(certificate), params: { payload_json: '{"key": HEADLESSSENTINEL0123456789' }

        expect(response).to have_http_status(:unprocessable_entity)
        expect(response.body).not_to include("HEADLESSSENTINEL")
        expect(response.body).to include("wasn't kept")
      end

      it "opens the editor from the cached document when Kong answers with non-JSON" do
        sign_in
        certificate = create_certificate
        stub_request(:get, "https://kong-admin.test/certificates/#{cert_id}").to_return(
          status: 200, body: "<html>proxy error</html>", headers: { "Content-Type" => "text/html" }
        )

        get edit_entity_path(certificate)

        expect(response).to have_http_status(:ok)
        expect(response.body).to include("{vault://env/cert-pay-key}")
      end

      it "withholds unparseable text from the certificate editor too, showing the live document" do
        sign_in
        certificate = create_certificate
        stub_request(:get, "https://kong-admin.test/certificates/#{cert_id}").to_return(status: 200, body: {
          id: cert_id, cert: pem[:cert_pem], key: "{vault://env/cert-pay-key}", snis: [], tags: [], updated_at: 1_700_000_000
        }.to_json)

        patch entity_path(certificate), params: { payload_json: '{"key": HEADLESSSENTINEL0123456789' }

        expect(response).to have_http_status(:unprocessable_entity)
        expect(response.body).not_to include("HEADLESSSENTINEL")
        expect(response.body).to include("wasn't kept")
        expect(response.body).to include("{vault://env/cert-pay-key}")
      end

      it "still keeps the operator's text for a type that carries no key material" do
        sign_in

        post entities_path, params: { type: "upstream", payload_json: "{ \"name\": oops-kept" }

        expect(response).to have_http_status(:unprocessable_entity)
        expect(response.body).to include("oops-kept")
        expect(response.body).not_to include("wasn't kept")
      end

      it "does not echo a key pasted without its BEGIN line, in key or key_alt" do
        sign_in
        body_lines = private_key_pem.lines[1..-2].map(&:strip).join
        headless = "#{body_lines}\n-----END PRIVATE KEY-----"

        post entities_path, params: { type: "certificate",
          payload_json: { cert: pem[:cert_pem], key: headless, key_alt: body_lines }.to_json }

        expect(response).to have_http_status(:unprocessable_entity)
        expect(response.body).not_to include(body_lines[0, 40])
        expect(ChangePlan.count).to eq(0)
      end

      it "keeps a reference-shaped key on the re-rendered editor and still blanks anything else" do
        sign_in
        secret = "not-a-reference-#{SecureRandom.hex(8)}"

        post entities_path, params: { type: "certificate",
          payload_json: { cert: pem[:cert_pem], key: "{vault://env/cert-NAME-key}", key_alt: secret }.to_json }

        expect(response).to have_http_status(:unprocessable_entity)
        expect(response.body).to include("{vault://env/cert-NAME-key}")
        expect(response.body).not_to include(secret)
      end

      it "does not echo a key sitting in an unparseable body's PEM block even without a closing quote" do
        sign_in
        truncated = "{ \"key\": \"#{private_key_pem.lines.first(3).join}"

        post entities_path, params: { type: "certificate", payload_json: truncated }

        expect(response).to have_http_status(:unprocessable_entity)
        expect(response.body).not_to include("BEGIN PRIVATE KEY")
        expect(response.body).not_to include(private_key_pem.lines[1].strip)
      end

      it "does not echo unquoted key text through the JSON parse error banner" do
        sign_in
        body_text = private_key_pem.lines[1..-2].map(&:strip).join[0, 60]

        post entities_path, params: { type: "certificate", payload_json: "{\"cert\":\"c\",\"key\": #{body_text}}" }

        expect(response).to have_http_status(:unprocessable_entity)
        expect(response.body).to include("isn&#39;t valid JSON")
        expect(response.body).to match(/line \d+ column \d+/)
        expect(response.body).not_to include(body_text[0, 20])
        expect(ChangePlan.count).to eq(0)
      end

      it "does not echo unquoted key text through the parse error banner of the certificate editor" do
        sign_in
        certificate = create_certificate
        stub_request(:get, "https://kong-admin.test/certificates/#{cert_id}").to_return(status: 200, body: {
          id: cert_id, cert: pem[:cert_pem], key: "{vault://env/cert-pay-key}", snis: [], tags: [], updated_at: 1_700_000_000
        }.to_json)
        body_text = private_key_pem.lines[1..-2].map(&:strip).join[0, 60]

        patch entity_path(certificate), params: { payload_json: "{\"key\": #{body_text}}" }

        expect(response).to have_http_status(:unprocessable_entity)
        expect(response.body).not_to include(body_text[0, 20])
      end

      it "blanks a key or key_alt that is an array or object, not just a string" do
        sign_in
        headless = private_key_pem.lines[1..-2].map(&:strip).join

        post entities_path, params: { type: "certificate",
          payload_json: { cert: pem[:cert_pem], key: [ headless[800, 80], headless[900, 80] ], key_alt: { "x" => headless[1000, 80] } }.to_json }

        expect(response).to have_http_status(:unprocessable_entity)
        # Offsets past the modulus: the cert on screen legitimately carries the public half.
        [ 800, 900, 1000 ].each { |offset| expect(response.body).not_to include(headless[offset, 40]) }
        expect(ChangePlan.count).to eq(0)
      end

      it "proposes an SNI under its certificate, carrying the reference" do
        sign_in
        create_certificate
        stub_request(:post, "https://kong-admin.test/schemas/snis/validate").to_return(ok)

        post entities_path, params: { type: "sni", parent_kong_id: cert_id, payload_json: { name: "api.example.internal" }.to_json }

        plan = ChangePlan.last
        expect(response).to redirect_to(change_plan_path(plan))
        expect(plan.after).to eq({ "name" => "api.example.internal", "certificate" => { "id" => cert_id } })
      end

      it "proposes a CA certificate" do
        sign_in
        stub_request(:post, "https://kong-admin.test/schemas/ca_certificates/validate").to_return(ok)

        post entities_path, params: { type: "ca_certificate", payload_json: { cert: pem[:cert_pem] }.to_json }

        expect(ChangePlan.last.entity_type).to eq("ca_certificate")
      end

      it "refuses a PEM typed into key_alt from the certificate editor, and re-renders without it" do
        sign_in
        certificate = create_certificate
        stub_request(:get, "https://kong-admin.test/certificates/#{cert_id}").to_return(status: 200, body: {
          id: cert_id, cert: pem[:cert_pem], key: "{vault://env/cert-pay-key}", snis: [ "pay.example.internal" ], tags: [], updated_at: 1_700_000_000
        }.to_json)

        patch entity_path(certificate), params: { payload_json: { key_alt: private_key_pem }.to_json }

        expect(response).to have_http_status(:unprocessable_entity)
        expect(response.body).to include("key_alt")
        expect(response.body).not_to include("BEGIN PRIVATE KEY")
        expect(ChangePlan.count).to eq(0)
      end

      it "keeps the [REDACTED] key marker through a re-render, and resubmitting what it shows is not refused by the key policy" do
        sign_in
        certificate = create_certificate(key: "[REDACTED]")
        stub_request(:get, "https://kong-admin.test/certificates/#{cert_id}").to_return(status: 200, body: {
          id: cert_id, cert: pem[:cert_pem], key: "[REDACTED]", snis: [ "pay.example.internal" ], tags: [], updated_at: 1_700_000_000
        }.to_json)
        validate = stub_request(:post, "https://kong-admin.test/schemas/certificates/validate")
        validate.to_return(status: 400, body: { message: "schema violation", fields: { tags: "expected an array" } }.to_json)
          .then.to_return(ok)

        patch entity_path(certificate), params: { payload_json: { key: "[REDACTED]", key_alt: "[REDACTED]", tags: "oops" }.to_json }

        expect(response).to have_http_status(:unprocessable_entity)
        shown = Nokogiri::HTML(response.body).at_css("textarea[name=payload_json]").text
        expect(JSON.parse(shown)).to include("key" => "[REDACTED]", "key_alt" => "[REDACTED]")

        patch entity_path(certificate), params: { payload_json: JSON.parse(shown).merge("tags" => [ "ok" ]).to_json }

        expect(response.body).not_to include("can&#39;t be set from here")
        expect(response).to redirect_to(change_plan_path(ChangePlan.last))
      end

      it "opens the certificate editor on the live document, with the reference and no plaintext hint about redaction" do
        sign_in
        certificate = create_certificate
        stub_request(:get, "https://kong-admin.test/certificates/#{cert_id}").to_return(status: 200, body: {
          id: cert_id, cert: pem[:cert_pem], key: "{vault://env/cert-pay-key}", snis: [ "pay.example.internal" ], tags: [], updated_at: 1_700_000_000
        }.to_json)

        get edit_entity_path(certificate)

        expect(response.body).to include("{vault://env/cert-pay-key}")
        expect(response.body).to include("reference")
        expect(response.body).not_to include("can&#39;t be set here")
      end
    end
  end
end
