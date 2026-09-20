require "rails_helper"

RSpec.describe "AuditEvents (web)", type: :request do
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
    get audit_events_path
    expect(response).to redirect_to(root_path)
  end

  it "lists audit events for the current connection, newest first" do
    sign_in
    older = create(:audit_event, kong_connection: connection, entity_name: "old-svc", created_at: 2.days.ago)
    newer = create(:audit_event, kong_connection: connection, entity_name: "new-svc", created_at: 1.hour.ago)
    create(:audit_event, kong_connection: create(:kong_connection), entity_name: "other-connection-svc")

    get audit_events_path

    expect(response.body).to include("new-svc")
    expect(response.body).to include("old-svc")
    expect(response.body).not_to include("other-connection-svc")
    expect(response.body.index("new-svc")).to be < response.body.index("old-svc")
  end

  it "shows the operator alongside the username for shared-credential changes" do
    sign_in
    create(:audit_event, kong_connection: connection, actor_username: "kong-admin", actor_operator: "bob")

    get audit_events_path

    expect(response.body).to include("kong-admin")
    expect(response.body).to include("bob")
  end
end
