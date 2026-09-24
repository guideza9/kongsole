require "rails_helper"
require Rails.root.join("spec/support/ui_snapshots")

# Renders real pages to tmp/ui-snapshots/*.html so `npx impeccable detect`
# (which cannot read .erb) has something to scan. Writes only when
# UI_SNAPSHOTS=1; otherwise each example just proves its page renders.
#
#   UI_SNAPSHOTS=1 bundle exec rspec spec/requests/ui_snapshots_spec.rb
#   npx impeccable detect --json tmp/ui-snapshots
RSpec.describe "UI snapshots", type: :request do
  include UiSnapshots

  it "writes the connections index with the stylesheet inlined" do
    create(:kong_connection, name: "dev-1")
    get connections_path
    path = snapshot!("connections-index", force: true, dir: Pathname(Dir.mktmpdir))
    html = File.read(path)
    expect(html).to include("<style>")
    expect(html).not_to include('rel="stylesheet" href="/assets')
  end

  # CI runs the suite without `tailwindcss:build`, and the build is gitignored.
  it "still writes a snapshot when the Tailwind build is missing" do
    stub_const("UiSnapshots::TAILWIND", Rails.root.join("tmp", "no-such-tailwind.css"))
    create(:kong_connection, name: "dev-1")
    get connections_path
    html = File.read(snapshot!("connections-index", force: true, dir: Pathname(Dir.mktmpdir)))
    expect(html).to include("<style>")
  end

  describe "pages" do
    let(:connection) { create(:kong_connection, admin_url: "https://kong-admin.test", credential_mode: "session") }

    def sign_in(conn = connection)
      base = conn.admin_url
      stub_request(:get, "#{base}/").to_return(status: 200, body: { version: "3.7.0" }.to_json)
      stub_request(:patch, "#{base}#{Kong::AccessProbe::PROBE_PATH}")
        .to_return(status: 404, body: { message: "Not found" }.to_json)
      stub_request(:get, "#{base}/consumers/alice").to_return(status: 200, body: { tags: [] }.to_json)
      stub_request(:get, "#{base}/routes").to_return(status: 200, body: { data: [], offset: nil }.to_json)
      # Entity forms read Kong's schema for reference rows (R3.3); a 404 means hints only.
      stub_request(:get, %r{\A#{Regexp.escape(base)}/schemas/[a-z_]+\z}).to_return(status: 404, body: { message: "Not found" }.to_json)
      post login_connection_path(conn), params: { username: "alice", password: "pw" }
    end

    it "login" do
      get login_connection_path(connection)
      snapshot!("login")
    end

    it "login on uat (R3.6)" do
      get login_connection_path(create(:kong_connection, name: "uat-1", env: "uat", rank: 2, apply_mode: "pr"))
      snapshot!("login-uat")
    end

    it "health" do
      create(:kong_connection, name: "sit", last_status: "ok")
      get health_path
      snapshot!("health")
    end

    it "connections new" do
      get new_connection_path
      snapshot!("connections-new")
    end

    Kong::EntityTypes::DEFINITIONS.each_key do |type|
      it "entities index: #{type} tab" do
        sign_in
        get entities_path(type: type)
        snapshot!("entities-index-#{type}")
      end
    end

    it "entity show" do
      sign_in
      entity = create(:kong_entity, kong_connection: connection, name: "payments-api", data: { "host" => "backend.internal" })
      get entity_path(entity)
      snapshot!("entity-show")
    end

    %w[upstream certificate ca_certificate].each do |type|
      it "entities new: #{type}" do
        sign_in
        get new_entity_path(type: type)
        snapshot!("entities-new-#{type}")
      end
    end

    it "entities new: target (under its upstream)" do
      sign_in
      upstream = create(:kong_entity, kong_connection: connection, entity_type: "upstream", name: "payments-upstream")
      get new_entity_path(type: "target", parent_kong_id: upstream.kong_id)
      snapshot!("entities-new-target")
    end

    it "entities new: sni (under its certificate)" do
      sign_in
      certificate = create(:kong_entity, kong_connection: connection, entity_type: "certificate", name: "api.example.test")
      get new_entity_path(type: "sni", parent_kong_id: certificate.kong_id)
      snapshot!("entities-new-sni")
    end

    it "plugins new: catalog step" do
      sign_in
      connection.update!(plugins_available: { "available_on_server" => { "acl" => {}, "rate-limiting" => {} } })
      get new_plugin_path
      snapshot!("plugins-new-catalog")
    end

    it "plugins new: config step" do
      sign_in
      stub_request(:get, "https://kong-admin.test/schemas/plugins/rate-limiting").to_return(status: 200, body: {
        fields: [ { config: { fields: [
          { second: { type: "integer", description: "Requests per second.", required: false } },
          { policy: { type: "string", default: "local", one_of: %w[local redis] } }
        ] } } ]
      }.to_json)
      get new_plugin_path(plugin_name: "rate-limiting")
      snapshot!("plugins-new-config")
    end

    it "change plan show: direct" do
      sign_in
      get change_plan_path(create(:change_plan, kong_connection: connection))
      snapshot!("change-plan-direct")
    end

    it "change plan show: pr" do
      sign_in
      plan = create(:change_plan, kong_connection: connection, apply_mode: "pr", before: { "name" => "svc" }, after: { "name" => "svc" })
      get change_plan_path(plan)
      snapshot!("change-plan-pr")
    end

    it "change plan show: delete" do
      sign_in
      get change_plan_path(create(:change_plan, :delete, kong_connection: connection))
      snapshot!("change-plan-delete")
    end

    it "change plans index" do
      sign_in
      create(:change_plan, kong_connection: connection, apply_mode: "pr", before: { "name" => "svc" }, after: { "name" => "svc" })
      get change_plans_path
      snapshot!("change-plans-index")
    end

    it "audit events index" do
      sign_in
      create(:audit_event, kong_connection: connection)
      get audit_events_path
      snapshot!("audit-events-index")
    end

    it "personal access tokens index" do
      sign_in
      get personal_access_tokens_path
      snapshot!("tokens-index")
    end

    it "personal access tokens new" do
      sign_in
      get new_personal_access_token_path
      snapshot!("tokens-new")
    end

    it "layout with compact hints (R3.4)" do
      cookies[:kongsole_hints] = "compact"
      create(:kong_connection, name: "dev-1")
      get connections_path
      expect(response.body).to include(I18n.t("hints.ui.toggle.show"))
      snapshot!("layout-compact-hints")
    end

    it "an alert with its cause and next step (R3.4)" do
      sign_in
      entity = create(:kong_entity, kong_connection: connection, kong_id: "47474747-4747-4747-4747-474747474747", name: "payments-api")
      stub_request(:get, "https://kong-admin.test/services/#{entity.kong_id}")
        .to_return(status: 404, body: { message: "no Route matched with those values" }.to_json)
      patch entity_path(entity), params: { tags: "payment", enabled: "1" }
      follow_redirect!
      expect(response.body).to include(I18n.t("hints.ui.next_step"), CGI.escapeHTML(I18n.t("hints.errors.route_not_matched.next_step")))
      snapshot!("alert-error-explanation")
    end

    it "certificates expiring" do
      sign_in
      get expiring_certificates_path
      snapshot!("certificates-expiring")
    end
  end
end
