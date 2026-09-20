require "rails_helper"

RSpec.describe Kong::EntitySync do
  # Kong entity ids are always real UUIDs -- kong_entities.kong_id is a uuid
  # column, so anything else silently casts to nil (a presence-validation
  # failure, not a type error) and every fixture id below has to be shaped
  # like one.
  SVC_1 = "11111111-1111-1111-1111-111111111111"
  SVC_2 = "22222222-2222-2222-2222-222222222222"
  SVC_ADMIN = "aaaaaaaa-aaaa-aaaa-aaaa-aaaaaaaaaaaa"
  SVC_GONE = "99999999-9999-9999-9999-999999999999"

  let(:connection) do
    create(:kong_connection, admin_url: "https://kong-admin.internal", auth_username: "kongctl",
      admin_path_fingerprint: { "service_id" => SVC_ADMIN })
  end
  let(:client) { Kong::Client.new(connection: connection, secret: "pw") }
  let(:sync) { described_class.new(connection: connection, client: client, entity_type: "service") }

  describe "#call" do
    it "syncs services into kong_entities, redacting data and computing a digest" do
      stub_request(:get, "https://kong-admin.internal/services")
        .with(query: { size: "100" })
        .to_return(status: 200, body: {
          data: [
            { id: SVC_1, name: "payments-api", tags: [ "payment" ], enabled: true,
              created_at: 1_700_000_000, updated_at: 1_700_000_100, host: "backend.internal" },
            { id: SVC_ADMIN, name: "admin-api", tags: [ "kong-admin-path" ], enabled: true,
              created_at: 1_700_000_000, updated_at: 1_700_000_000, host: "127.0.0.1" }
          ],
          offset: nil
        }.to_json)

      result = sync.call

      expect(result.synced_count).to eq(2)
      expect(result.removed_count).to eq(0)

      payments = KongEntity.find_by(kong_id: SVC_1)
      expect(payments.name).to eq("payments-api")
      expect(payments.logical_key).to eq("payments-api")
      expect(payments.tags).to eq([ "payment" ])
      expect(payments.is_admin_path).to eq(false)
      expect(payments.digest).to be_present
      expect(payments.kong_created_at).to eq(Time.zone.at(1_700_000_000))

      admin_entity = KongEntity.find_by(kong_id: SVC_ADMIN)
      expect(admin_entity.is_admin_path).to eq(true)
    end

    it "pages through Kong's offset cursor until exhausted" do
      stub_request(:get, "https://kong-admin.internal/services")
        .with(query: { size: "100" })
        .to_return(status: 200, body: { data: [ { id: SVC_1, name: "one" } ], offset: "cursor-1" }.to_json)
      stub_request(:get, "https://kong-admin.internal/services")
        .with(query: { size: "100", offset: "cursor-1" })
        .to_return(status: 200, body: { data: [ { id: SVC_2, name: "two" } ], offset: nil }.to_json)

      result = sync.call

      expect(result.synced_count).to eq(2)
      expect(KongEntity.pluck(:kong_id)).to contain_exactly(SVC_1, SVC_2)
    end

    it "soft-deletes entities that no longer come back from Kong" do
      create(:kong_entity, kong_connection: connection, entity_type: "service", kong_id: SVC_GONE, name: "gone")

      stub_request(:get, "https://kong-admin.internal/services")
        .with(query: { size: "100" })
        .to_return(status: 200, body: { data: [ { id: SVC_1, name: "one" } ], offset: nil }.to_json)

      result = sync.call

      expect(result.removed_count).to eq(1)
      expect(KongEntity.find_by(kong_id: SVC_GONE).deleted_at).to be_present
      expect(KongEntity.active.pluck(:kong_id)).to contain_exactly(SVC_1)
    end

    it "upserts on a second run rather than duplicating rows" do
      stub_request(:get, "https://kong-admin.internal/services")
        .with(query: { size: "100" })
        .to_return(status: 200, body: { data: [ { id: SVC_1, name: "one", updated_at: 1_700_000_000 } ], offset: nil }.to_json)
        .times(2)

      sync.call
      sync.call

      expect(KongEntity.where(kong_id: SVC_1).count).to eq(1)
    end

    it "syncs a route with a logical_key resolved against its already-synced parent service" do
      create(:kong_entity, kong_connection: connection, entity_type: "service", kong_id: SVC_1, name: "payments-api")
      route_id = "33333333-3333-3333-3333-333333333333"
      route_sync = described_class.new(connection: connection, client: client, entity_type: "route")
      stub_request(:get, "https://kong-admin.internal/routes")
        .with(query: { size: "100" })
        .to_return(status: 200, body: { data: [
          { id: route_id, name: "charge", service: { id: SVC_1 }, tags: [] }
        ], offset: nil }.to_json)

      route_sync.call

      route = KongEntity.find_by(kong_id: route_id)
      expect(route.name).to eq("charge")
      expect(route.logical_key).to eq("payments-api/charge")
      expect(route.parent_type).to eq("service")
      expect(route.parent_kong_id).to eq(SVC_1)
    end

    it "falls back to the parent id's first 8 chars for a route whose service hasn't been synced yet" do
      route_id = "33333333-3333-3333-3333-333333333333"
      route_sync = described_class.new(connection: connection, client: client, entity_type: "route")
      stub_request(:get, "https://kong-admin.internal/routes")
        .with(query: { size: "100" })
        .to_return(status: 200, body: { data: [
          { id: route_id, name: nil, service: { id: SVC_1 }, tags: [] }
        ], offset: nil }.to_json)

      route_sync.call

      route = KongEntity.find_by(kong_id: route_id)
      expect(route.name).to eq(route_id[0..7])
      expect(route.logical_key).to eq("#{SVC_1[0..7]}/#{route_id[0..7]}")
    end

    it "syncs a consumer by username, falling back to custom_id" do
      consumer_id = "44444444-4444-4444-4444-444444444444"
      consumer_sync = described_class.new(connection: connection, client: client, entity_type: "consumer")
      stub_request(:get, "https://kong-admin.internal/consumers")
        .with(query: { size: "100" })
        .to_return(status: 200, body: { data: [
          { id: consumer_id, username: "alice", custom_id: nil, tags: [] }
        ], offset: nil }.to_json)

      consumer_sync.call

      consumer = KongEntity.find_by(kong_id: consumer_id)
      expect(consumer.name).to eq("alice")
      expect(consumer.logical_key).to eq("alice")
    end

    it "syncs a keyauth credential's name from the consumer, never from the redacted key" do
      consumer_id = "44444444-4444-4444-4444-444444444444"
      cred_id = "55555555-5555-5555-5555-555555555555"
      create(:kong_entity, kong_connection: connection, entity_type: "consumer", kong_id: consumer_id, name: "alice")
      cred_sync = described_class.new(connection: connection, client: client, entity_type: "keyauth_credential")
      stub_request(:get, "https://kong-admin.internal/key-auths")
        .with(query: { size: "100" })
        .to_return(status: 200, body: { data: [
          { id: cred_id, key: "super-secret-key", consumer: { id: consumer_id }, tags: [] }
        ], offset: nil }.to_json)

      cred_sync.call

      credential = KongEntity.find_by(kong_id: cred_id)
      expect(credential.name).to eq("alice/#{cred_id[0..7]}")
      expect(credential.name).not_to include("super-secret-key")
      expect(credential.parent_type).to eq("consumer")
      expect(credential.parent_kong_id).to eq(consumer_id)
      expect(credential.data["key"]).to eq("[REDACTED]")
    end

    it "syncs a service-scoped plugin, resolving parent_type/parent_kong_id from Kong's own reference" do
      svc_id = "11111111-1111-1111-1111-111111111111"
      plugin_id = "66666666-6666-6666-6666-666666666666"
      plugin_sync = described_class.new(connection: connection, client: client, entity_type: "plugin")
      stub_request(:get, "https://kong-admin.internal/plugins")
        .with(query: { size: "100" })
        .to_return(status: 200, body: { data: [
          { id: plugin_id, name: "rate-limiting", service: { id: svc_id }, route: nil, consumer: nil,
            enabled: true, tags: [] }
        ], offset: nil }.to_json)

      plugin_sync.call

      plugin = KongEntity.find_by(kong_id: plugin_id)
      expect(plugin.name).to eq("rate-limiting")
      expect(plugin.parent_type).to eq("service")
      expect(plugin.parent_kong_id).to eq(svc_id)
      expect(plugin.logical_key).to eq("rate-limiting@service:#{svc_id[0..7]}")
      expect(plugin.enabled).to eq(true)
    end

    it "syncs a global plugin with no scope reference at all" do
      plugin_id = "77777777-7777-7777-7777-777777777777"
      plugin_sync = described_class.new(connection: connection, client: client, entity_type: "plugin")
      stub_request(:get, "https://kong-admin.internal/plugins")
        .with(query: { size: "100" })
        .to_return(status: 200, body: { data: [
          { id: plugin_id, name: "prometheus", service: nil, route: nil, consumer: nil, enabled: true, tags: [] }
        ], offset: nil }.to_json)

      plugin_sync.call

      plugin = KongEntity.find_by(kong_id: plugin_id)
      expect(plugin.parent_type).to be_nil
      expect(plugin.parent_kong_id).to be_nil
      expect(plugin.logical_key).to eq("prometheus@global")
    end

    it "syncs a route-scoped and a consumer-scoped plugin, each resolving its own scope kind" do
      route_id = "88888888-8888-8888-8888-888888888888"
      consumer_id = "99999999-9999-9999-9999-999999999999"
      plugin_sync = described_class.new(connection: connection, client: client, entity_type: "plugin")
      stub_request(:get, "https://kong-admin.internal/plugins")
        .with(query: { size: "100" })
        .to_return(status: 200, body: { data: [
          { id: "aaaaaaaa-1111-1111-1111-111111111111", name: "cors", service: nil, route: { id: route_id }, consumer: nil, enabled: true, tags: [] },
          { id: "bbbbbbbb-1111-1111-1111-111111111111", name: "jwt", service: nil, route: nil, consumer: { id: consumer_id }, enabled: true, tags: [] }
        ], offset: nil }.to_json)

      plugin_sync.call

      route_plugin = KongEntity.find_by(kong_id: "aaaaaaaa-1111-1111-1111-111111111111")
      consumer_plugin = KongEntity.find_by(kong_id: "bbbbbbbb-1111-1111-1111-111111111111")
      expect(route_plugin.parent_type).to eq("route")
      expect(route_plugin.parent_kong_id).to eq(route_id)
      expect(consumer_plugin.parent_type).to eq("consumer")
      expect(consumer_plugin.parent_kong_id).to eq(consumer_id)
    end
  end

  describe ".sync_connection" do
    it "syncs every M0-M3 entity type in dependency order (services/consumers before routes/credentials)" do
      %w[services consumers routes key-auths basic-auths plugins].each do |path|
        stub_request(:get, "https://kong-admin.internal/#{path}")
          .with(query: { size: "100" })
          .to_return(status: 200, body: { data: [], offset: nil }.to_json)
      end

      result = described_class.sync_connection(connection: connection, client: client)

      expect(result.synced_count).to eq(0)
      %w[services consumers routes key-auths basic-auths plugins].each do |path|
        expect(WebMock).to have_requested(:get, "https://kong-admin.internal/#{path}").with(query: { size: "100" })
      end
    end
  end
end
