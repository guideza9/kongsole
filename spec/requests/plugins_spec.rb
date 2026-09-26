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
    it "lists every plugin loaded on this node, including ones with no instance yet" do
      sign_in
      connection.update!(plugins_available: {
        "enabled_in_cluster" => %w[acl basic-auth],
        "available_on_server" => { "acl" => {}, "basic-auth" => {}, "rate-limiting" => {}, "my-custom" => {} }
      })

      get new_plugin_path

      %w[acl basic-auth rate-limiting my-custom].each { |name| expect(response.body).to include(name) }
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
      stub_request(:post, "https://kong-admin.test/schemas/plugins/validate").to_return(status: 200, body: "{}")
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
      stub_request(:post, "https://kong-admin.test/schemas/plugins/validate").to_return(status: 200, body: "{}")

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

  # R4.5: the catalog, the schema form, the scope picker and the version check.
  describe "the schema-driven flow" do
    let(:schema_json) { File.read(Rails.root.join("spec/fixtures/schemas/rate_limiting_like.json")) }

    def stub_schema(host = "https://kong-admin.test")
      stub_request(:get, "#{host}/schemas/plugins/rate-limiting").to_return(status: 200, body: schema_json)
    end

    it "lists the catalog as bundled and custom entries" do
      sign_in
      connection.update!(plugins_available: { "available_on_server" => { "rate-limiting" => { "version" => "3.7.1" }, "team-auth" => {} } })
      get new_plugin_path
      expect(response.body).to include("rate-limiting", "team-auth", "Bundled with Kong", "Custom")
    end

    # R4.6: the catalog is searchable, grouped, and says when a custom plugin
    # has no description and how to add one.
    it "gives the catalog a labelled search, the two groups, and the missing-description hint" do
      sign_in
      connection.update!(plugins_available: { "available_on_server" => { "rate-limiting" => { "version" => "3.7.1" }, "team-headers" => {} } })
      get new_plugin_path

      page = Nokogiri::HTML(response.body)
      search = page.at_css('input[type="search"]')
      expect(search).to be_present
      expect(page.at_css("label[for='#{search['id']}']")).to be_present
      expect(page.css("h2").map { _1.text.strip }).to include("Bundled with Kong", "Custom")
      expect(response.body).to include("No description provided for this custom plugin", "config/custom_plugins/team-headers.yml")
      expect(response.body).to include(I18n.t("hints.plugins.rate-limiting.summary"))
    end

    it "shows the scope the plugin will be added to with the scope mark" do
      sign_in
      service = create(:kong_entity, kong_connection: connection, entity_type: "service", name: "billing")
      get new_plugin_path(scope_type: "service", scope_kong_id: service.kong_id)
      page = Nokogiri::HTML(response.body)
      expect(page.at_css(".scope .scope__name")&.text).to eq("billing")
    end

    it "offers every scope, without admin-path entities" do
      sign_in
      stub_schema
      create(:kong_entity, kong_connection: connection, entity_type: "service", name: "billing")
      create(:kong_entity, kong_connection: connection, entity_type: "service", name: "admin-api", is_admin_path: true)
      get new_plugin_path(plugin_name: "rate-limiting")
      expect(response.body).to include("billing")
      expect(response.body).not_to include("admin-api")
    end

    it "renders a control per config field, a secret one without a value" do
      sign_in
      stub_schema
      get new_plugin_path(plugin_name: "rate-limiting")
      expect(response.body).to include('name="plugin[config][minute]"', 'name="plugin[config][policy]"')
      expect(response.body).to match(/<input[^>]*type="password"[^>]*name="plugin\[config\]\[api_key\]"|<input[^>]*name="plugin\[config\]\[api_key\]"[^>]*type="password"/)
    end

    it "creates from form fields and lands on the plan review (direct) with Kong's schema validation" do
      sign_in
      connection.update!(access_level: "rw")
      service = create(:kong_entity, kong_connection: connection, entity_type: "service", name: "billing")
      stub_schema
      validate = stub_request(:post, "https://kong-admin.test/schemas/plugins/validate").to_return(status: 200, body: "{}")

      post plugins_path, params: { plugin_name: "rate-limiting", scope_type: "service", scope_kong_id: service.kong_id,
        plugin: { config: { minute: "60" }, enabled: "1" } }

      plan = ChangePlan.last
      expect(response).to redirect_to(change_plan_path(plan))
      expect(plan.after["config"]["minute"]).to eq(60)
      expect(plan.after["service"]).to eq("id" => service.kong_id)
      expect(validate).to have_been_requested
    end

    it "takes the scope from the picker's one select" do
      sign_in
      service = create(:kong_entity, kong_connection: connection, entity_type: "service", name: "billing")
      stub_schema
      stub_request(:post, "https://kong-admin.test/schemas/plugins/validate").to_return(status: 200, body: "{}")

      post plugins_path, params: { plugin_name: "rate-limiting", scope: "service:#{service.kong_id}", plugin: { config: { minute: "60" } } }

      expect(ChangePlan.last.after["service"]).to eq("id" => service.kong_id)
    end

    it "re-renders with the field's own error for a bad value" do
      sign_in
      connection.update!(access_level: "rw")
      stub_schema
      post plugins_path, params: { plugin_name: "rate-limiting", plugin: { config: { minute: "abc" } } }
      expect(response).to have_http_status(:unprocessable_entity)
      expect(response.body).to include("config.minute")
      expect(ChangePlan.count).to eq(0)
    end

    it "puts a PR-mode plugin into the changeset and refuses plaintext secrets" do
      env = create(:project_env, name: "uat", apply_mode: "pr", source: "registry", select_tags: %w[managed-by-kongctl])
      pr_connection = create(:kong_connection, admin_url: "https://kong-uat.test", project_env: env)
      sign_in_to(pr_connection, access: :ro)
      stub_schema("https://kong-uat.test")

      post plugins_path, params: { plugin_name: "rate-limiting", plugin: { config: { api_key: "sk_live_1" } } }
      expect(response).to have_http_status(:unprocessable_entity)
      expect(response.body).not_to include("sk_live_1")

      post plugins_path, params: { plugin_name: "rate-limiting", plugin: { config: { api_key: "{vault://env/rl-api-key}" } } }
      expect(response).to redirect_to(changeset_path(ChangePlan.last.changeset))
      expect(a_request(:any, /kong-uat\.test/).with { |req| req.method != :get && req.uri.path != Kong::AccessProbe::PROBE_PATH }).not_to have_been_made
    end

    # Review Focus 5.
    it "warns when another env of the project has a different schema for the plugin" do
      sign_in
      stub_schema
      uat = create(:kong_connection, kong_version: "3.8.0",
        project_env: create(:project_env, project: connection.project, name: "uat", position: 9))
      KongSchema.create!(kong_connection: uat, kind: "plugin", name: "rate-limiting", kong_version: "3.8.0",
        digest: "other", body: {}, fetched_at: Time.current)

      get new_plugin_path(plugin_name: "rate-limiting")

      expect(response.body).to include("Schema differs on uat (Kong 3.8.0)")
    end

    it "explains why Kong's schema could not be read" do
      sign_in
      stub_request(:get, "https://kong-admin.test/schemas/plugins/rate-limiting").to_return(status: 503, body: "{}")
      get new_plugin_path(plugin_name: "rate-limiting")
      expect(response).to redirect_to(new_plugin_path)
      expect(flash[:error_explanation]).to be_present
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

  # R1.13: no plugin form where the write would be refused.
  describe "where nothing can be written" do
    let(:unset) { create(:kong_connection, admin_url: "https://kong-unset.test", apply_mode: nil) }

    before { sign_in_to(unset) }

    it "sends the catalog back to the plugin list with the reason" do
      get new_plugin_path

      expect(response).to redirect_to(entities_path(type: "plugin"))
      expect(flash[:alert]).to include("apply mode is not set")
    end

    it "refuses a create without reaching Kong" do
      post plugins_path, params: { plugin_name: "cors", payload_json: {}.to_json }

      expect(response).to redirect_to(entities_path(type: "plugin"))
      expect(ChangePlan.count).to eq(0)
    end
  end
end
