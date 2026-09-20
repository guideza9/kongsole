require "rails_helper"

RSpec.describe Kong::AccessProbe do
  let(:connection) { build(:kong_connection, admin_url: "http://kong-admin.test", auth_username: "kongctl") }
  let(:client) { Kong::Client.new(connection: connection, secret: "pw") }

  it "reports ro when Kong's router rejects the write (read-only route)" do
    stub_request(:patch, "http://kong-admin.test#{Kong::AccessProbe::PROBE_PATH}")
      .to_return(status: 404, body: { message: "no Route matched with those values" }.to_json)

    expect(described_class.new(client).call).to eq("ro")
  end

  it "reports rw when the Admin API answers (even with entity-not-found, since the request reached it)" do
    stub_request(:patch, "http://kong-admin.test#{Kong::AccessProbe::PROBE_PATH}")
      .to_return(status: 404, body: { message: "Not found" }.to_json)

    expect(described_class.new(client).call).to eq("rw")
  end
end
