require "rails_helper"

RSpec.describe Kong::CredentialClassifier do
  let(:connection) { build(:kong_connection, admin_url: "http://kong-admin.test", auth_username: "kong-admin", shared_usernames: [ "kong-admin" ]) }
  let(:client) { Kong::Client.new(connection: connection, secret: "pw") }

  it "classifies as shared when the consumer carries the shared-credential tag" do
    stub_request(:get, "http://kong-admin.test/consumers/kong-admin")
      .to_return(status: 200, body: { tags: [ "shared-credential" ] }.to_json)

    expect(described_class.new(client, connection).call).to eq("shared")
  end

  it "classifies as personal when the consumer has no shared-credential tag" do
    stub_request(:get, "http://kong-admin.test/consumers/kong-admin")
      .to_return(status: 200, body: { tags: [ "team-a" ] }.to_json)

    expect(described_class.new(client, connection).call).to eq("personal")
  end

  it "falls back to connections.yml shared_usernames when the consumer lookup fails" do
    stub_request(:get, "http://kong-admin.test/consumers/kong-admin")
      .to_return(status: 403, body: { message: "You cannot consume this service" }.to_json)

    expect(described_class.new(client, connection).call).to eq("shared")
  end

  it "defaults to personal on lookup failure when the username isn't in shared_usernames" do
    connection.shared_usernames = []
    stub_request(:get, "http://kong-admin.test/consumers/kong-admin")
      .to_return(status: 403, body: { message: "You cannot consume this service" }.to_json)

    expect(described_class.new(client, connection).call).to eq("personal")
  end
end
