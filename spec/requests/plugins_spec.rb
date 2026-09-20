require "rails_helper"

RSpec.describe "Plugins (web)", type: :request do
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

  describe "GET /plugins/new (catalog step)" do
    it "lists only the plugins actually loaded on this Kong node, not everything the binary ships with" do
      sign_in
      connection.update!(plugins_available: {
        "enabled_in_cluster" => %w[acl basic-auth],
        "available_on_server" => { "acl" => {}, "basic-auth" => {}, "rate-limiting" => {} }
      })

      get new_plugin_path

      expect(response.body).to include("acl")
      expect(response.body).to include("basic-auth")
      expect(response.body).not_to include("rate-limiting")
    end
  end

  describe "GET /plugins/new?plugin_name=... (config step)" do
    it "seeds the editor from the schema's defaults and renders the reference panel" do
      sign_in
      stub_request(:get, "https://kong-admin.test/schemas/plugins/rate-limiting").to_return(status: 200, body: {
        fields: [
          { config: { fields: [
            { second: { type: "integer", description: "Requests per second.", required: false } },
            { policy: { type: "string", default: "local", description: "Rate-limiting counter storage.", one_of: %w[local redis] } }
          ] } }
        ]
      }.to_json)

      get new_plugin_path(plugin_name: "rate-limiting")

      expect(response.body).to include("&quot;name&quot;: &quot;rate-limiting&quot;")
      expect(response.body).to include("&quot;policy&quot;: &quot;local&quot;") # seeded from the schema's default
      expect(response.body).to include("Requests per second.") # schema reference panel
      expect(response.body).to include("local, redis") # one_of rendered
    end

    it "scopes the flow to whatever entity it was entered from" do
      sign_in
      service = create(:kong_entity, kong_connection: connection, entity_type: "service", name: "payments-api")
      stub_request(:get, "https://kong-admin.test/schemas/plugins/cors")
        .to_return(status: 200, body: { fields: [ { config: { fields: [] } } ] }.to_json)

      get new_plugin_path(plugin_name: "cors", scope_type: "service", scope_kong_id: service.kong_id)

      expect(response.body).to include("service: payments-api")
    end
  end

  describe "POST /plugins (create)" do
    it "proposes a plugin scoped to a service, landing on the same review pipeline as everything else" do
      sign_in
      service = create(:kong_entity, kong_connection: connection, entity_type: "service", name: "payments-api")

      post plugins_path, params: {
        scope_type: "service", scope_kong_id: service.kong_id, plugin_name: "cors",
        payload_json: { name: "cors", config: {} }.to_json
      }

      expect(response).to redirect_to(change_plan_path(ChangePlan.last))
      plan = ChangePlan.last
      expect(plan.entity_type).to eq("plugin")
      expect(plan.after["service"]).to eq({ "id" => service.kong_id })
      expect(plan.parent_kong_id).to eq(service.kong_id)
    end

    it "proposes a global plugin when no scope is given at all" do
      sign_in

      post plugins_path, params: { plugin_name: "prometheus", payload_json: { name: "prometheus", config: {} }.to_json }

      expect(response).to redirect_to(change_plan_path(ChangePlan.last))
      expect(ChangePlan.last.after).not_to have_key("service")
      expect(ChangePlan.last.after).not_to have_key("route")
      expect(ChangePlan.last.after).not_to have_key("consumer")
    end

    it "re-renders the config step with the operator's edit intact when the JSON doesn't parse" do
      sign_in
      stub_request(:get, "https://kong-admin.test/schemas/plugins/cors")
        .to_return(status: 200, body: { fields: [ { config: { fields: [] } } ] }.to_json)

      post plugins_path, params: { plugin_name: "cors", payload_json: '{ "name": "cors",, }' }

      expect(response).to have_http_status(:unprocessable_entity)
      expect(response.body).to include("&quot;name&quot;: &quot;cors&quot;,, }") # the edit survived the round trip
      expect(response.body).to include("isn&#39;t valid JSON")
      expect(ChangePlan.count).to eq(0)
    end

    it "refuses to attach a new plugin to the connection's own admin route" do
      sign_in
      admin_route_id = "dddddddd-dddd-dddd-dddd-dddddddddddd"
      connection.update!(admin_path_fingerprint: { "route_ids" => [ admin_route_id ] })

      post plugins_path, params: {
        scope_type: "route", scope_kong_id: admin_route_id, plugin_name: "rate-limiting",
        payload_json: { name: "rate-limiting", config: {} }.to_json
      }

      expect(response).to redirect_to(new_plugin_path(scope_type: "route", scope_kong_id: admin_route_id))
      follow_redirect!
      expect(response.body).to include("read-only")
      expect(ChangePlan.count).to eq(0)
    end
  end

  describe "read-only admin-path plugins" do
    it "shows no edit/delete controls for the plugin fronting this connection's own admin path" do
      sign_in
      plugin_id = "eeeeeeee-eeee-eeee-eeee-eeeeeeeeeeee"
      connection.update!(admin_path_fingerprint: { "plugin_ids" => [ plugin_id ] })
      plugin = create(:kong_entity, kong_connection: connection, entity_type: "plugin", kong_id: plugin_id,
        name: "acl", is_admin_path: true)

      get entity_path(plugin)

      expect(response.body).to include("Read-only")
      expect(response.body).not_to include(">Edit<")
      expect(response.body).not_to include(">Delete<")
    end

    it "still shows controls for an ordinary, non-admin-path plugin" do
      sign_in
      plugin = create(:kong_entity, kong_connection: connection, entity_type: "plugin", name: "cors")

      get entity_path(plugin)

      expect(response.body).to include(">Edit<")
      expect(response.body).to include(">Delete<")
    end
  end
end
