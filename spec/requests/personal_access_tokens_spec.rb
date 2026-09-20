require "rails_helper"

RSpec.describe "PersonalAccessTokens (web)", type: :request do
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
    get personal_access_tokens_path
    expect(response).to redirect_to(root_path)
  end

  it "only offers stored-mode connections when issuing a token" do
    sign_in
    stored = create(:kong_connection, name: "stored-conn", credential_mode: "stored")
    create(:kong_connection, name: "session-conn", credential_mode: "session")

    get new_personal_access_token_path

    expect(response.body).to include("stored-conn")
    expect(response.body).not_to include("session-conn")
  end

  it "issues a token bound to the chosen stored connections and shows the raw token once" do
    sign_in
    stored = create(:kong_connection, credential_mode: "stored")

    post personal_access_tokens_path, params: { operator: "bob", name: "laptop", connection_ids: [ stored.id ] }

    expect(response).to redirect_to(personal_access_tokens_path)
    follow_redirect!
    expect(response.body).to match(/kctl_[0-9a-f]+/)
    expect(PersonalAccessToken.last.operator).to eq("bob")
    expect(PersonalAccessToken.last.kong_connections).to contain_exactly(stored)
  end

  it "rejects issuing a token against a session-mode connection" do
    sign_in
    session_conn = create(:kong_connection, credential_mode: "session")

    post personal_access_tokens_path, params: { operator: "bob", connection_ids: [ session_conn.id ] }

    expect(response).to have_http_status(:unprocessable_entity)
    expect(PersonalAccessToken.count).to eq(0)
  end

  it "revokes a token" do
    sign_in
    pat = create(:personal_access_token)

    post revoke_personal_access_token_path(pat)

    expect(pat.reload.revoked?).to eq(true)
  end
end
