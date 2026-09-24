require "rails_helper"

RSpec.describe Kong::ConnectionLogin do
  let(:connection) { create(:kong_connection, admin_url: "https://kong-admin.test", credential_mode: "session") }

  def stub_successful_login(access_probe_status: 404, access_probe_message: "Not found")
    stub_request(:get, "https://kong-admin.test/")
      .to_return(status: 200, body: { version: "3.7.0", configuration: { database: "postgres" } }.to_json)
    stub_request(:patch, "https://kong-admin.test#{Kong::AccessProbe::PROBE_PATH}")
      .to_return(status: access_probe_status, body: { message: access_probe_message }.to_json)
    stub_request(:get, "https://kong-admin.test/consumers/alice")
      .to_return(status: 200, body: { tags: [] }.to_json)
    stub_request(:get, "https://kong-admin.test/routes")
      .to_return(status: 200, body: { data: [], offset: nil }.to_json)
  end

  it "runs the full pipeline and records access level, credential kind, and the admin path fingerprint" do
    stub_successful_login

    result = described_class.new(connection: connection, username: "alice", secret: "pw").call

    expect(result).to be_success
    expect(connection.reload.kong_version).to eq("3.7.0")
    expect(connection.access_level).to eq("rw")
    expect(connection.credential_kind).to eq("personal")
    expect(connection.last_status).to eq("ok")
    expect(connection.last_connected_at).to be_present
  end

  it "does not persist the secret for a session-mode connection" do
    stub_successful_login
    described_class.new(connection: connection, username: "alice", secret: "pw").call
    expect(connection.reload.auth_secret).to be_nil
  end

  it "persists the encrypted secret for a stored-mode connection" do
    connection.update!(credential_mode: "stored")
    stub_successful_login
    described_class.new(connection: connection, username: "alice", secret: "pw").call
    expect(connection.reload.auth_secret).to eq("pw")
  end

  it "fails closed when a shared credential is used without an operator" do
    stub_successful_login
    stub_request(:get, "https://kong-admin.test/consumers/alice")
      .to_return(status: 200, body: { tags: [ "shared-credential" ] }.to_json)

    result = described_class.new(connection: connection, username: "alice", secret: "pw").call

    expect(result).not_to be_success
    expect(result.error).to match(/operator/)
  end

  it "succeeds with a shared credential when an operator is given" do
    stub_successful_login
    stub_request(:get, "https://kong-admin.test/consumers/alice")
      .to_return(status: 200, body: { tags: [ "shared-credential" ] }.to_json)

    result = described_class.new(connection: connection, username: "alice", secret: "pw", operator: "bob@example.com").call

    expect(result).to be_success
    expect(connection.reload.credential_kind).to eq("shared")
  end

  it "records a typed failure and status on a rejected credential, without raising" do
    stub_request(:get, "https://kong-admin.test/")
      .to_return(status: 401, body: { message: "Unauthorized" }.to_json)

    result = described_class.new(connection: connection, username: "alice", secret: "wrong").call

    expect(result).not_to be_success
    expect(result.error_class).to eq(Kong::Client::Unauthorized)
    expect(connection.reload.last_status).to eq("unauthorized")
  end

  # R3.2 keeps the stored status as before; R1.11 splits out "unreachable".
  it "still records an unreachable network as unavailable, and hands back the error for explaining" do
    stub_request(:get, "https://kong-admin.test/")
      .to_raise(Faraday::ConnectionFailed.new(SocketError.new("getaddrinfo: Name or service not known")))

    result = described_class.new(connection: connection, username: "alice", secret: "pw").call

    expect(result.exception).to be_a(Kong::Client::NetworkUnreachable)
    expect(result.exception.kind).to eq(:dns)
    expect(connection.reload.last_status).to eq("unavailable")
  end
end
