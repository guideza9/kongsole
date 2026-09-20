require "rails_helper"

RSpec.describe Kong::AdminPathGuard do
  let(:connection) { build(:kong_connection, admin_url: "https://kong-admin.internal/", auth_username: "kongctl") }
  let(:client) { Kong::Client.new(connection: connection, secret: "pw") }

  describe "#call" do
    context "when the admin_url resolves to a service that loops back to 127.0.0.1" do
      before do
        stub_request(:get, "https://kong-admin.internal/routes").to_return(
          status: 200,
          body: {
            data: [
              { id: "route-1", hosts: [ "kong-admin.internal" ], paths: [], service: { id: "svc-1" } },
              { id: "route-x", hosts: [ "unrelated.internal" ], paths: [], service: { id: "svc-x" } }
            ],
            offset: nil
          }.to_json
        )
        stub_request(:get, "https://kong-admin.internal/services/svc-1")
          .to_return(status: 200, body: { id: "svc-1", url: "http://127.0.0.1:8001" }.to_json)
        stub_request(:get, "https://kong-admin.internal/services/svc-1/routes")
          .to_return(status: 200, body: { data: [ { id: "route-1" }, { id: "route-2" } ], offset: nil }.to_json)
        stub_request(:get, "https://kong-admin.internal/services/svc-1/plugins")
          .to_return(status: 200, body: { data: [ { id: "plugin-1", name: "basic-auth" } ], offset: nil }.to_json)
        stub_request(:get, "https://kong-admin.internal/routes/route-1/plugins")
          .to_return(status: 200, body: { data: [ { id: "plugin-2", name: "acl", config: { allow: [ "kong-admin-rw" ] } } ], offset: nil }.to_json)
        stub_request(:get, "https://kong-admin.internal/routes/route-2/plugins")
          .to_return(status: 200, body: { data: [ { id: "plugin-3", name: "acl", config: { allow: [ "kong-admin-ro" ] } } ], offset: nil }.to_json)
        stub_request(:get, "https://kong-admin.internal/plugins/plugin-1")
          .to_return(status: 200, body: { id: "plugin-1", name: "basic-auth" }.to_json)
        stub_request(:get, "https://kong-admin.internal/plugins/plugin-2")
          .to_return(status: 200, body: { id: "plugin-2", name: "acl", config: { allow: [ "kong-admin-rw" ] } }.to_json)
        stub_request(:get, "https://kong-admin.internal/plugins/plugin-3")
          .to_return(status: 200, body: { id: "plugin-3", name: "acl", config: { allow: [ "kong-admin-ro" ] } }.to_json)
        stub_request(:get, "https://kong-admin.internal/acls").to_return(
          status: 200,
          body: {
            data: [
              { group: "kong-admin-rw", consumer: { id: "consumer-1" } },
              { group: "kong-admin-ro", consumer: { id: "consumer-2" } },
              { group: "unrelated", consumer: { id: "consumer-3" } }
            ],
            offset: nil
          }.to_json
        )
      end

      it "marks the service, every route on it, every plugin on those, and every allowed consumer" do
        fingerprint = described_class.new(client, connection).call

        expect(fingerprint["service_id"]).to eq("svc-1")
        expect(fingerprint["route_ids"]).to contain_exactly("route-1", "route-2")
        expect(fingerprint["plugin_ids"]).to contain_exactly("plugin-1", "plugin-2", "plugin-3")
        expect(fingerprint["consumer_ids"]).to contain_exactly("consumer-1", "consumer-2")
      end

      it "is then usable to guard entities via .admin_path?" do
        fingerprint = described_class.new(client, connection).call

        expect(described_class.admin_path?(fingerprint, "svc-1")).to eq(true)
        expect(described_class.admin_path?(fingerprint, "route-2")).to eq(true)
        expect(described_class.admin_path?(fingerprint, "consumer-1")).to eq(true)
        expect(described_class.admin_path?(fingerprint, "consumer-3")).to eq(false)
        expect(described_class.admin_path?(fingerprint, "unrelated-service")).to eq(false)
      end
    end

    context "when no route matches the admin_url" do
      before do
        stub_request(:get, "https://kong-admin.internal/routes")
          .to_return(status: 200, body: { data: [], offset: nil }.to_json)
      end

      it "returns an empty fingerprint rather than guessing" do
        fingerprint = described_class.new(client, connection).call
        expect(fingerprint["service_id"]).to be_nil
        expect(fingerprint["route_ids"]).to eq([])
      end
    end

    context "when the matching route's service does not loop back to localhost" do
      before do
        stub_request(:get, "https://kong-admin.internal/routes").to_return(
          status: 200,
          body: { data: [ { id: "route-1", hosts: [ "kong-admin.internal" ], paths: [], service: { id: "svc-1" } } ], offset: nil }.to_json
        )
        stub_request(:get, "https://kong-admin.internal/services/svc-1")
          .to_return(status: 200, body: { id: "svc-1", url: "http://payments.internal:80" }.to_json)
      end

      it "does not mark it as an admin path" do
        fingerprint = described_class.new(client, connection).call
        expect(fingerprint["service_id"]).to be_nil
      end
    end
  end
end
