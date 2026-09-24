require "rails_helper"

# The console says the same thing the same way: times as one local stamp,
# states as one badge, and "pick one of these" as one tab. These read the
# rendered pages, so a page that drifts back to its own dialect fails here.
RSpec.describe "Console consistency", type: :request do
  let(:connection) { create(:kong_connection, admin_url: "https://kong-admin.test", credential_mode: "session") }

  def sign_in
    stub_request(:get, "https://kong-admin.test/").to_return(status: 200, body: { version: "3.7.0" }.to_json)
    stub_request(:patch, "https://kong-admin.test#{Kong::AccessProbe::PROBE_PATH}").to_return(status: 404, body: { message: "Not found" }.to_json)
    stub_request(:get, "https://kong-admin.test/consumers/alice").to_return(status: 200, body: { tags: [] }.to_json)
    stub_request(:get, "https://kong-admin.test/routes").to_return(status: 200, body: { data: [], offset: nil }.to_json)
    # Entity forms read Kong's schema for reference rows (R3.3); a 404 means hints only.
    stub_request(:get, %r{\Ahttps://kong-admin\.test/schemas/[a-z_]+\z}).to_return(status: 404, body: { message: "Not found" }.to_json)
    post login_connection_path(connection), params: { username: "alice", password: "pw" }
  end

  def page
    Nokogiri::HTML(response.body)
  end

  # R3: every field says what it is for, and every empty page how to begin.
  describe "hints" do
    # Visible form fields whose aria-describedby is missing or points at no text.
    def undescribed_fields
      page.css("main input, main select, main textarea")
        .reject { |el| %w[hidden submit button].include?(el["type"]) }
        .reject do |el|
          ids = el["aria-describedby"].to_s.split
          ids.any? && ids.all? { |id| page.at_css("[id='#{id}']")&.text.to_s.strip.present? }
        end
        .map { |el| el["name"] || el["id"] }
    end

    it "describes every field on the connection form" do
      get new_connection_path
      expect(undescribed_fields).to eq([])
    end

    it "describes every field on the login form" do
      get login_connection_path(connection)
      expect(undescribed_fields).to eq([])
    end

    it "describes every field on the token form" do
      sign_in
      create(:kong_connection, name: "dev-stored", credential_mode: "stored")
      get new_personal_access_token_path
      expect(undescribed_fields).to eq([])
    end

    it "describes every field on the entity edit form and the entity filter" do
      sign_in
      entity = create(:kong_entity, kong_connection: connection, name: "payments-api")
      stub_request(:get, "https://kong-admin.test/services/#{entity.kong_id}")
        .to_return(status: 200, body: { id: entity.kong_id, name: "payments-api", tags: [] }.to_json)

      get edit_entity_path(entity)
      expect(undescribed_fields).to eq([])

      get entities_path(type: "service")
      expect(undescribed_fields).to eq([])
    end

    it "describes the JSON editor on a create form and the plugin config step" do
      sign_in
      get new_entity_path(type: "upstream")
      expect(undescribed_fields).to eq([])

      stub_request(:get, "https://kong-admin.test/schemas/plugins/cors")
        .to_return(status: 200, body: { fields: [ { config: { fields: [] } } ] }.to_json)
      get new_plugin_path(plugin_name: "cors")
      expect(undescribed_fields).to eq([])
    end

    it "tells a connection that has never synced apart from a filter that matches nothing" do
      sign_in
      get entities_path(type: "service")
      expect(response.body).to include(I18n.t("hints.empty_states.entities.never_synced.title"))

      create(:kong_entity, kong_connection: connection, name: "payments-api")
      get entities_path(type: "service", q: "nothing-like-this")
      expect(response.body).to include(I18n.t("hints.empty_states.entities.no_match.title", type: "services"))
    end

    it "explains what a delete does before the review asks to confirm it" do
      sign_in
      get change_plan_path(create(:change_plan, :delete, kong_connection: connection))
      expect(response.body).to include(I18n.t("hints.risks.delete_entity.title"))
    end

    it "says Kong refuses to delete a service that still has routes, rather than taking them with it" do
      sign_in
      get change_plan_path(create(:change_plan, :delete, kong_connection: connection))
      expect(response.body).to include(I18n.t("hints.risks.delete_entity.body"))
      expect(I18n.t("hints.risks.delete_entity.body")).to match(/refuses/i).and(satisfy { |body| !body.include?("takes its routes") })
    end

    it "keeps the admin-path warning for the admin path, and asks for the entity's own name" do
      sign_in
      admin_id = "abababab-abab-abab-abab-abababababab"
      connection.update!(admin_path_fingerprint: { "service_id" => admin_id })
      get change_plan_path(create(:change_plan, :delete, kong_connection: connection, target_kong_id: admin_id,
        before: { "id" => admin_id, "name" => "admin-api", "tags" => [] }))
      expect(response.body).to include(I18n.t("hints.risks.delete_admin_path.title"))
      expect(I18n.t("hints.risks.delete_admin_path.body")).not_to include("connection name")
    end

    it "warns about a protected entity as protected, not as the admin path" do
      sign_in
      get change_plan_path(create(:change_plan, :delete, kong_connection: connection,
        before: { "id" => SecureRandom.uuid, "name" => "payments-api", "tags" => [ "protected" ] }))
      expect(response.body).to include(I18n.t("hints.risks.delete_protected.title"))
      expect(response.body).not_to include(I18n.t("hints.risks.delete_admin_path.title"))
    end

    it "only promises a pull request on a uat login whose connection is in PR mode" do
      direct = create(:kong_connection, name: "uat-direct", env: "uat", rank: 2, apply_mode: "direct")
      get login_connection_path(direct)
      expect(response.body).not_to include(I18n.t("hints.risks.rank_2_login.pr_note"))

      pr = create(:kong_connection, name: "uat-pr", env: "uat", rank: 2, apply_mode: "pr")
      get login_connection_path(pr)
      expect(response.body).to include(I18n.t("hints.risks.rank_2_login.pr_note"))
    end

    it "explains what a uat login means before the credential is typed" do
      uat = create(:kong_connection, name: "uat-1", env: "uat", rank: 2, apply_mode: "pr")
      get login_connection_path(uat)
      expect(response.body).to include(I18n.t("hints.risks.rank_2_login.title", env: "UAT"))
    end
  end

  describe "health" do
    it "gives every connection a Log in and a Details action, and reads its policy in words and badges" do
      other = create(:kong_connection, name: "uat-ro", env: "uat", access_level: "ro", credential_kind: "shared",
        last_connected_at: Time.utc(2026, 9, 21, 14, 5), admin_path_fingerprint: { "service_id" => "s1" })

      get health_path

      row = page.css("tbody tr").find { |tr| tr.text.include?("uat-ro") }
      expect(row.css("a").map { |a| [ a.text.strip, a["href"] ] }).to eq([ [ "Log in", login_connection_path(other) ], [ "Details", connection_path(other) ] ])
      expect(row.text).to include("Read-only").and include("Shared")
      expect(row.at_css(".chip-ok").text).to include("Guarded")
      expect(row.at_css("time[data-controller='local-time']")["datetime"]).to eq("2026-09-21T14:05:00Z")
      expect(page.css("thead th").map { |th| th.text.strip }).to include("Actions")
    end

    it "says a connection with no admin path found is Unknown, in a badge" do
      create(:kong_connection, name: "fresh")

      get health_path

      expect(page.css("tbody tr").find { |tr| tr.text.include?("fresh") }.css(".chip-neutral").map(&:text).join).to include("Unknown")
    end
  end

  describe "timestamps" do
    before { sign_in }

    it "uses the shared local timestamp in the audit log" do
      create(:audit_event, kong_connection: connection)

      get audit_events_path

      expect(page.css("tbody time[data-controller='local-time']").size).to eq(1)
      expect(response.body).not_to match(/\d{2} [A-Z][a-z]{2} \d{2}:\d{2}/)
    end

    it "uses it for an entity's times, in the list and on its page" do
      entity = create(:kong_entity, kong_connection: connection, name: "payments-api")

      get entities_path
      expect(page.css("#entities-list time[data-controller='local-time']").size).to eq(1)

      get entity_path(entity)
      expect(page.css("dl time[data-controller='local-time']").size).to be >= 3
    end

    it "uses it for a token's dates, and shows a revoked one as a badge" do
      token = create(:personal_access_token, issued_by_username: "alice")
      token.update!(revoked_at: Time.current)

      get personal_access_tokens_path

      expect(page.css("time[data-controller='local-time']").size).to be >= 2
      expect(page.at_css(".chip-danger").text).to include("Revoked")
    end
  end

  describe "tabs" do
    before { sign_in }

    it "uses one tab style for the entity types, the expiry window and the upstream preset" do
      get entities_path
      expect(page.css("nav[aria-label='Entity types'] a").map { |a| a["class"] }.uniq).to eq([ "tab" ])

      get expiring_certificates_path
      expect(page.css("nav[aria-label='Window'] a").map { |a| a["class"] }.uniq).to eq([ "tab" ])

      get new_entity_path(type: "upstream")
      expect(page.css("nav[aria-label='Start from'] a").map { |a| a["class"] }.uniq).to eq([ "tab" ])
    end

    it "marks the current tab by aria-current alone, never a per-page class" do
      get expiring_certificates_path(days: 30)

      current = page.css("nav[aria-label='Window'] a[aria-current]")
      expect(current.map { |a| a.text.strip }).to eq([ "30 days" ])
    end
  end
end
