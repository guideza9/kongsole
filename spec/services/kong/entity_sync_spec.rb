require "rails_helper"
require Rails.root.join("spec/support/pem_fixtures")

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

  describe "upstreams and targets (M5a)" do
    let(:upstream_id) { "aaaaaaaa-0000-0000-0000-00000000000a" }
    let(:other_upstream_id) { "bbbbbbbb-0000-0000-0000-00000000000b" }
    let(:target_id) { "cccccccc-0000-0000-0000-00000000000c" }
    let(:upstream_sync) { described_class.new(connection: connection, client: client, entity_type: "upstream") }
    let(:target_sync) { described_class.new(connection: connection, client: client, entity_type: "target") }

    def targets_url(id)
      "https://kong-admin.internal/upstreams/#{id}/targets"
    end

    def stub_targets(id, targets, offset: nil, query: { size: "100" })
      stub_request(:get, targets_url(id)).with(query: query)
        .to_return(status: 200, body: { data: targets, offset: offset }.to_json)
    end

    it "syncs an upstream by name, with no parent" do
      stub_request(:get, "https://kong-admin.internal/upstreams")
        .with(query: { size: "100" })
        .to_return(status: 200, body: { data: [
          { id: upstream_id, name: "orders", algorithm: "round-robin", tags: [ "core" ],
            created_at: 1_700_000_000, updated_at: 1_700_000_100 }
        ], offset: nil }.to_json)

      result = upstream_sync.call

      expect(result.synced_count).to eq(1)
      upstream = KongEntity.find_by(kong_id: upstream_id)
      expect(upstream.entity_type).to eq("upstream")
      expect(upstream.name).to eq("orders")
      expect(upstream.logical_key).to eq("orders")
      expect(upstream.parent_type).to be_nil
      expect(upstream.tags).to eq([ "core" ])
      expect(upstream.data["algorithm"]).to eq("round-robin")
    end

    it "lists targets under each synced upstream, since Kong 3.7 has no global /targets" do
      create(:kong_entity, kong_connection: connection, entity_type: "upstream", kong_id: upstream_id, name: "orders")
      create(:kong_entity, kong_connection: connection, entity_type: "upstream", kong_id: other_upstream_id, name: "billing")
      stub_targets(upstream_id, [ { id: target_id, target: "10.0.0.1:8080", weight: 100, upstream: { id: upstream_id }, tags: [] } ])
      stub_targets(other_upstream_id, [
        { id: "dddddddd-0000-0000-0000-00000000000d", target: "10.0.1.1:9000", weight: 10, upstream: { id: other_upstream_id }, tags: [] }
      ])

      result = target_sync.call

      expect(result.synced_count).to eq(2)
      expect(WebMock).not_to have_requested(:get, "https://kong-admin.internal/targets")
      target = KongEntity.find_by(kong_id: target_id)
      expect(target.entity_type).to eq("target")
      expect(target.name).to eq("10.0.0.1:8080")
      expect(target.logical_key).to eq("orders/10.0.0.1:8080")
      expect(target.parent_type).to eq("upstream")
      expect(target.parent_kong_id).to eq(upstream_id)
      expect(target.data["weight"]).to eq(100)
    end

    it "falls back to the upstream id's first 8 chars when the upstream hasn't been synced under that name" do
      create(:kong_entity, kong_connection: connection, entity_type: "upstream", kong_id: upstream_id, name: nil, logical_key: nil)
      stub_targets(upstream_id, [ { id: target_id, target: "10.0.0.1:8080", upstream: { id: upstream_id }, tags: [] } ])

      target_sync.call

      expect(KongEntity.find_by(kong_id: target_id).logical_key).to eq("#{upstream_id[0..7]}/10.0.0.1:8080")
    end

    it "pages through one upstream's targets with Kong's offset cursor" do
      create(:kong_entity, kong_connection: connection, entity_type: "upstream", kong_id: upstream_id, name: "orders")
      stub_targets(upstream_id, [ { id: target_id, target: "10.0.0.1:8080", upstream: { id: upstream_id } } ], offset: "1")
      stub_targets(upstream_id,
        [ { id: "dddddddd-0000-0000-0000-00000000000d", target: "10.0.0.2:8080", upstream: { id: upstream_id } } ],
        query: { size: "100", offset: "1" })

      result = target_sync.call

      expect(result.synced_count).to eq(2)
    end

    it "makes no target requests, and removes nothing it shouldn't, when there are no upstreams" do
      result = target_sync.call

      expect(result.synced_count).to eq(0)
      expect(result.removed_count).to eq(0)
      expect(WebMock).not_to have_requested(:get, /upstreams/)
    end

    it "soft-deletes a target that no longer comes back from its upstream" do
      create(:kong_entity, kong_connection: connection, entity_type: "upstream", kong_id: upstream_id, name: "orders")
      gone = create(:kong_entity, kong_connection: connection, entity_type: "target",
        kong_id: "eeeeeeee-0000-0000-0000-00000000000e", name: "10.9.9.9:80", parent_type: "upstream", parent_kong_id: upstream_id)
      stub_targets(upstream_id, [ { id: target_id, target: "10.0.0.1:8080", upstream: { id: upstream_id } } ])

      result = target_sync.call

      expect(result.removed_count).to eq(1)
      expect(gone.reload.deleted_at).to be_present
      expect(KongEntity.active.where(entity_type: "target").pluck(:kong_id)).to contain_exactly(target_id)
    end

    it "soft-deletes the targets of an upstream that is no longer in the read-model" do
      orphan = create(:kong_entity, kong_connection: connection, entity_type: "target",
        kong_id: "eeeeeeee-0000-0000-0000-00000000000e", name: "10.9.9.9:80", parent_type: "upstream", parent_kong_id: other_upstream_id)

      result = target_sync.call

      expect(result.removed_count).to eq(1)
      expect(orphan.reload.deleted_at).to be_present
    end

    it "treats an upstream Kong reports gone mid-sync as having no targets, and keeps syncing the rest" do
      create(:kong_entity, kong_connection: connection, entity_type: "upstream", kong_id: upstream_id, name: "orders")
      create(:kong_entity, kong_connection: connection, entity_type: "upstream", kong_id: other_upstream_id, name: "billing")
      stale = create(:kong_entity, kong_connection: connection, entity_type: "target",
        kong_id: "eeeeeeee-0000-0000-0000-00000000000e", name: "10.9.9.9:80", parent_type: "upstream", parent_kong_id: upstream_id)
      stub_request(:get, targets_url(upstream_id)).with(query: { size: "100" })
        .to_return(status: 404, body: { message: "Not found" }.to_json)
      stub_targets(other_upstream_id, [ { id: target_id, target: "10.0.1.1:9000", upstream: { id: other_upstream_id } } ])

      result = target_sync.call

      expect(result.synced_count).to eq(1)
      expect(stale.reload.deleted_at).to be_present
    end

    it "does not swallow other Admin API errors while listing targets" do
      create(:kong_entity, kong_connection: connection, entity_type: "upstream", kong_id: upstream_id, name: "orders")
      stub_request(:get, targets_url(upstream_id)).with(query: { size: "100" })
        .to_return(status: 503, body: "")

      expect { target_sync.call }.to raise_error(Kong::Client::Error)
    end

    it "re-syncs a single target through its nested member path (sync_one)" do
      create(:kong_entity, kong_connection: connection, entity_type: "upstream", kong_id: upstream_id, name: "orders")
      stub_request(:get, "#{targets_url(upstream_id)}/#{target_id}")
        .to_return(status: 200, body: { id: target_id, target: "10.0.0.1:8080", weight: 50, upstream: { id: upstream_id }, tags: [] }.to_json)

      entity = described_class.sync_one(
        connection: connection, client: client, entity_type: "target", kong_id: target_id, parent_kong_id: upstream_id
      )

      expect(entity.logical_key).to eq("orders/10.0.0.1:8080")
      expect(entity.data["weight"]).to eq(50)
    end

    it "does not mark an upstream or a target as an admin-path entity" do
      create(:kong_entity, kong_connection: connection, entity_type: "upstream", kong_id: upstream_id, name: "orders")
      stub_targets(upstream_id, [ { id: target_id, target: "10.0.0.1:8080", upstream: { id: upstream_id } } ])

      target_sync.call

      expect(KongEntity.find_by(kong_id: target_id).is_admin_path).to eq(false)
    end
  end

  describe "certificates, SNIs and CA certificates (M5b)" do
    let(:cert_id) { "dddddddd-0000-0000-0000-00000000000d" }
    let(:sni_id) { "eeeeeeee-0000-0000-0000-00000000000e" }
    let(:ca_id) { "ffffffff-0000-0000-0000-00000000000f" }
    let(:fixture) { PemFixtures.self_signed(cn: "pay.example.internal", days: 45, sans: %w[pay.example.internal]) }
    let(:cert_sync) { described_class.new(connection: connection, client: client, entity_type: "certificate") }

    def stub_list(path, data)
      stub_request(:get, "https://kong-admin.internal/#{path}").with(query: { size: "100" })
        .to_return(status: 200, body: { data: data, offset: nil }.to_json)
    end

    def kong_cert(overrides = {})
      { id: cert_id, cert: fixture[:cert_pem], key: "{vault://env/cert-pay-key}", snis: %w[pay.example.internal api.example.internal],
        tags: [ "core" ], created_at: 1_700_000_000, updated_at: 1_700_000_100 }.merge(overrides)
    end

    it "names a certificate by its first SNI (sorted) and keys it by the sorted SNI list" do
      stub_list("certificates", [ kong_cert(snis: %w[b.example a.example]) ])

      cert_sync.call

      row = KongEntity.find_by(kong_id: cert_id)
      expect(row.entity_type).to eq("certificate")
      expect(row.name).to eq("a.example")
      expect(row.logical_key).to eq("a.example,b.example")
      expect(row.parent_type).to be_nil
    end

    it "falls back to the fingerprint's first 12 characters when the certificate has no SNI" do
      stub_list("certificates", [ kong_cert(snis: []) ])

      cert_sync.call

      row = KongEntity.find_by(kong_id: cert_id)
      expect(row.name).to eq(fixture[:der_sha256][0..11])
      expect(row.logical_key).to eq(fixture[:der_sha256])
    end

    it "caches metadata and the not_after column, and never the PEM" do
      stub_list("certificates", [ kong_cert(cert_alt: fixture[:cert_pem]) ])

      cert_sync.call

      row = KongEntity.find_by(kong_id: cert_id)
      expect(row.not_after).to be_within(5.seconds).of(45.days.from_now)
      expect(row.data).not_to have_key("cert")
      expect(row.data).not_to have_key("cert_alt")
      expect(row.data["_metadata"]).to include("fingerprint_sha256" => fixture[:der_sha256], "sans" => [ "DNS:pay.example.internal" ])
      expect(row.data.to_json).not_to include("BEGIN CERTIFICATE")
      expect(row.expiry_status).to eq("ok") # 45 days out is beyond the 30-day warning tier
    end

    it "keeps a vault reference readable but redacts a plaintext key that Kong hands back" do
      stub_list("certificates", [
        kong_cert,
        kong_cert(id: "99999999-0000-0000-0000-000000000009", snis: [ "legacy.example" ], key: fixture[:key_pem])
      ])

      cert_sync.call

      expect(KongEntity.find_by(kong_id: cert_id).data["key"]).to eq("{vault://env/cert-pay-key}")
      legacy = KongEntity.find_by(kong_id: "99999999-0000-0000-0000-000000000009")
      expect(legacy.data["key"]).to eq("[REDACTED]")
      expect(legacy.data.to_json).not_to include("PRIVATE KEY")
    end

    it "never fails a sync over a certificate whose PEM will not parse" do
      stub_list("certificates", [ kong_cert(cert: "garbage"), kong_cert(id: "88888888-0000-0000-0000-000000000008", snis: [ "ok.example" ]) ])

      result = cert_sync.call

      expect(result.synced_count).to eq(2)
      broken = KongEntity.find_by(kong_id: cert_id)
      expect(broken.not_after).to be_nil
      expect(broken.expiry_status).to be_nil
      expect(broken.data["_metadata"].keys).to eq([ "parse_error" ])
      expect(broken.name).to eq("api.example.internal") # named from the SNI list, which needs no PEM
    end

    it "re-syncing updates not_after and the digest when the certificate is replaced" do
      stub_list("certificates", [ kong_cert ])
      cert_sync.call
      first = KongEntity.find_by(kong_id: cert_id)

      renewed = PemFixtures.self_signed(cn: "pay.example.internal", days: 365)
      stub_list("certificates", [ kong_cert(cert: renewed[:cert_pem]) ])
      cert_sync.call

      second = KongEntity.find_by(kong_id: cert_id)
      expect(second.not_after).to be > first.not_after + 300.days
      expect(second.digest).not_to eq(first.digest)
      expect(KongEntity.where(kong_id: cert_id).count).to eq(1)
    end

    it "syncs an SNI by hostname, parented to its certificate" do
      stub_list("snis", [ { id: sni_id, name: "pay.example.internal", certificate: { id: cert_id }, tags: [] } ])

      described_class.new(connection: connection, client: client, entity_type: "sni").call

      row = KongEntity.find_by(kong_id: sni_id)
      expect(row.name).to eq("pay.example.internal")
      expect(row.logical_key).to eq("pay.example.internal")
      expect(row.parent_type).to eq("certificate")
      expect(row.parent_kong_id).to eq(cert_id)
      expect(row.not_after).to be_nil
    end

    it "syncs a CA certificate by its cert_digest, with metadata and expiry" do
      digest = "9852b7219ac320e83b0cddcc132766331667e7b290477751e5397eeb5aef4dd5"
      stub_list("ca_certificates", [ { id: ca_id, cert: fixture[:cert_pem], cert_digest: digest, tags: [] } ])

      described_class.new(connection: connection, client: client, entity_type: "ca_certificate").call

      row = KongEntity.find_by(kong_id: ca_id)
      expect(row.name).to eq(digest[0..11])
      expect(row.logical_key).to eq(digest)
      expect(row.not_after).to be_within(5.seconds).of(45.days.from_now)
      expect(row.data).not_to have_key("cert")
    end

    it "soft-deletes a certificate that is no longer in Kong" do
      gone = create(:kong_entity, kong_connection: connection, entity_type: "certificate",
        kong_id: "77777777-0000-0000-0000-000000000007", name: "old.example")
      stub_list("certificates", [ kong_cert ])

      result = cert_sync.call

      expect(result.removed_count).to eq(1)
      expect(gone.reload.deleted_at).to be_present
    end

    it "orders certificates before their SNIs in the connection sync" do
      order = described_class::TYPES_IN_SYNC_ORDER

      expect(order.index("certificate")).to be < order.index("sni")
      expect(order.last(3)).to eq(%w[certificate sni ca_certificate])
    end

    it "re-syncs a single certificate through sync_one (used after an SNI write)" do
      stub_request(:get, "https://kong-admin.internal/certificates/#{cert_id}")
        .to_return(status: 200, body: kong_cert(snis: [ "new.example" ]).to_json)

      entity = described_class.sync_one(connection: connection, client: client, entity_type: "certificate", kong_id: cert_id)

      expect(entity.name).to eq("new.example")
    end
  end

  describe ".sync_connection" do
    it "syncs every entity type in dependency order (services/consumers/upstreams before their children)" do
      %w[services consumers routes key-auths basic-auths plugins upstreams certificates snis ca_certificates].each do |path|
        stub_request(:get, "https://kong-admin.internal/#{path}")
          .with(query: { size: "100" })
          .to_return(status: 200, body: { data: [], offset: nil }.to_json)
      end

      result = described_class.sync_connection(connection: connection, client: client)

      expect(result.synced_count).to eq(0)
      %w[services consumers routes key-auths basic-auths plugins upstreams certificates snis ca_certificates].each do |path|
        expect(WebMock).to have_requested(:get, "https://kong-admin.internal/#{path}").with(query: { size: "100" })
      end
    end

    it "syncs upstreams before targets, so a just-created upstream's targets are fetched in the same run" do
      upstream_id = "aaaaaaaa-0000-0000-0000-00000000000a"
      %w[services consumers routes key-auths basic-auths plugins certificates snis ca_certificates].each do |path|
        stub_request(:get, "https://kong-admin.internal/#{path}")
          .with(query: { size: "100" })
          .to_return(status: 200, body: { data: [], offset: nil }.to_json)
      end
      stub_request(:get, "https://kong-admin.internal/upstreams").with(query: { size: "100" })
        .to_return(status: 200, body: { data: [ { id: upstream_id, name: "orders" } ], offset: nil }.to_json)
      stub_request(:get, "https://kong-admin.internal/upstreams/#{upstream_id}/targets").with(query: { size: "100" })
        .to_return(status: 200, body: { data: [
          { id: "cccccccc-0000-0000-0000-00000000000c", target: "10.0.0.1:8080", upstream: { id: upstream_id } }
        ], offset: nil }.to_json)

      result = described_class.sync_connection(connection: connection, client: client)

      expect(result.synced_count).to eq(2)
      expect(KongEntity.active.where(entity_type: "target").count).to eq(1)
    end
  end
end
