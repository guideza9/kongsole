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
    post login_connection_path(connection), params: { username: "alice", password: "pw" }
  end

  def page
    Nokogiri::HTML(response.body)
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
