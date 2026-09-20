require "rails_helper"

RSpec.describe "Sessions (connection login)", type: :request do
  let(:connection) { create(:kong_connection, admin_url: "https://kong-admin.test", credential_mode: "session") }

  def stub_successful_login
    stub_request(:get, "https://kong-admin.test/")
      .to_return(status: 200, body: { version: "3.7.0" }.to_json)
    stub_request(:patch, "https://kong-admin.test#{Kong::AccessProbe::PROBE_PATH}")
      .to_return(status: 404, body: { message: "Not found" }.to_json)
    stub_request(:get, "https://kong-admin.test/consumers/alice")
      .to_return(status: 200, body: { tags: [] }.to_json)
    stub_request(:get, "https://kong-admin.test/routes")
      .to_return(status: 200, body: { data: [], offset: nil }.to_json)
  end

  it "logs in and starts a session on valid credentials" do
    stub_successful_login

    post login_connection_path(connection), params: { username: "alice", password: "pw" }

    expect(response).to redirect_to(health_path)
    follow_redirect!
    expect(response.body).to include(connection.name)
  end

  it "never puts the raw password anywhere in the session cookie's visible state beyond the encrypted store" do
    stub_successful_login
    post login_connection_path(connection), params: { username: "alice", password: "correct-horse-battery-staple" }
    expect(response.cookies["_kong_integration_session"]).not_to include("correct-horse-battery-staple") if response.cookies["_kong_integration_session"]
  end

  it "shows a specific message on a rejected credential rather than a generic failure" do
    stub_request(:get, "https://kong-admin.test/")
      .to_return(status: 401, body: { message: "Unauthorized" }.to_json)

    post login_connection_path(connection), params: { username: "alice", password: "wrong" }

    expect(response).to have_http_status(:unprocessable_entity)
    expect(response.body).to include("wrong username or password")
  end

  it "signs out and clears the session" do
    stub_successful_login
    post login_connection_path(connection), params: { username: "alice", password: "pw" }

    delete logout_path
    expect(response).to redirect_to(root_path)

    get health_path
    expect(response.body).not_to include("Sign out")
  end
end
