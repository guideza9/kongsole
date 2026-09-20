require "rails_helper"

RSpec.describe Kong::ChangePlanner do
  PLANNER_SVC_1 = "11111111-1111-1111-1111-111111111111"
  PLANNER_ADMIN_SVC = "aaaaaaaa-aaaa-aaaa-aaaa-aaaaaaaaaaaa"

  let(:connection) do
    create(:kong_connection, admin_url: "https://kong-admin.internal", auth_username: "kongctl",
      access_level: "rw", admin_path_fingerprint: { "service_id" => PLANNER_ADMIN_SVC })
  end
  let(:client) { Kong::Client.new(connection: connection, secret: "pw") }

  def planner(**overrides)
    described_class.new(
      connection: connection, client: client, actor_username: "alice", entity_type: "service",
      **overrides
    )
  end

  describe "#call" do
    it "proposes an update, capturing before/after/diff from a live Kong fetch" do
      stub_request(:get, "https://kong-admin.internal/services/#{PLANNER_SVC_1}")
        .to_return(status: 200, body: { id: PLANNER_SVC_1, name: "payments-api", tags: [ "payment" ], updated_at: 1_700_000_000 }.to_json)

      plan = planner(operation: "update", target_kong_id: PLANNER_SVC_1, attributes: { "tags" => %w[payment deprecated] }).call

      expect(plan).to be_persisted
      expect(plan.status).to eq("pending")
      expect(plan.before["tags"]).to eq([ "payment" ])
      expect(plan.after["tags"]).to eq(%w[payment deprecated])
      expect(plan.diff).to eq({ "tags" => { "from" => [ "payment" ], "to" => %w[payment deprecated] } })
      expect(plan.base_updated_at).to eq(Time.zone.at(1_700_000_000))
      expect(plan.expires_at).to be_within(1.second).of(15.minutes.from_now)
    end

    it "proposes a delete without requiring a typed confirmation yet" do
      stub_request(:get, "https://kong-admin.internal/services/#{PLANNER_SVC_1}")
        .to_return(status: 200, body: { id: PLANNER_SVC_1, name: "payments-api", tags: [] }.to_json)

      plan = planner(operation: "delete", target_kong_id: PLANNER_SVC_1).call

      expect(plan.operation).to eq("delete")
      expect(plan.diff).to eq({ "operation" => "delete" })
    end

    it "proposes a delete of an admin-path entity without requiring confirmation yet either" do
      stub_request(:get, "https://kong-admin.internal/services/#{PLANNER_ADMIN_SVC}")
        .to_return(status: 200, body: { id: PLANNER_ADMIN_SVC, name: "admin-api", tags: [] }.to_json)

      plan = planner(operation: "delete", target_kong_id: PLANNER_ADMIN_SVC).call

      expect(plan).to be_persisted
    end

    it "rejects proposing any change on a read-only credential" do
      connection.update!(access_level: "ro")

      expect {
        planner(operation: "delete", target_kong_id: PLANNER_SVC_1).call
      }.to raise_error(Kong::ChangeGuardrails::Violation, /can't write/)
    end

    it "records the operator when a shared credential proposes the change" do
      stub_request(:get, "https://kong-admin.internal/services/#{PLANNER_SVC_1}")
        .to_return(status: 200, body: { id: PLANNER_SVC_1, name: "payments-api", tags: [] }.to_json)

      plan = planner(operation: "update", target_kong_id: PLANNER_SVC_1, attributes: { "tags" => [ "x" ] }, actor_operator: "bob").call

      expect(plan.actor_operator).to eq("bob")
    end

    it "records actor_kind human by default" do
      stub_request(:get, "https://kong-admin.internal/services/#{PLANNER_SVC_1}")
        .to_return(status: 200, body: { id: PLANNER_SVC_1, name: "payments-api", tags: [] }.to_json)

      plan = planner(operation: "update", target_kong_id: PLANNER_SVC_1, attributes: { "tags" => [ "x" ] }).call

      expect(plan.actor_kind).to eq("human")
    end

    it "rejects an agent proposing to delete an admin-path entity, at propose time, no plan created" do
      stub_request(:get, "https://kong-admin.internal/services/#{PLANNER_ADMIN_SVC}")
        .to_return(status: 200, body: { id: PLANNER_ADMIN_SVC, name: "admin-api", tags: [] }.to_json)

      expect {
        planner(operation: "delete", target_kong_id: PLANNER_ADMIN_SVC, actor_kind: "agent").call
      }.to raise_error(Kong::ChangeGuardrails::Violation, /no override/)
      expect(ChangePlan.count).to eq(0)
    end

    it "rejects an agent proposing to delete a protected-tagged (non-admin-path) entity too" do
      stub_request(:get, "https://kong-admin.internal/services/#{PLANNER_SVC_1}")
        .to_return(status: 200, body: { id: PLANNER_SVC_1, name: "payments-api", tags: [ "protected" ] }.to_json)

      expect {
        planner(operation: "delete", target_kong_id: PLANNER_SVC_1, actor_kind: "agent").call
      }.to raise_error(Kong::ChangeGuardrails::Violation, /no override/)
    end

    it "allows an agent to propose deleting a non-protected entity" do
      stub_request(:get, "https://kong-admin.internal/services/#{PLANNER_SVC_1}")
        .to_return(status: 200, body: { id: PLANNER_SVC_1, name: "payments-webhook", tags: [] }.to_json)

      plan = planner(operation: "delete", target_kong_id: PLANNER_SVC_1, actor_kind: "agent").call

      expect(plan.actor_kind).to eq("agent")
    end

    it "proposes a route create against /routes, resolving the path via Kong::EntityTypes" do
      plan = planner(entity_type: "route", operation: "create", attributes: { "name" => "charge", "paths" => [ "/charge" ] }).call

      expect(plan.entity_type).to eq("route")
      expect(plan.after).to eq({ "name" => "charge", "paths" => [ "/charge" ] })
      expect(plan.diff).to eq({ "operation" => "create" })
    end

    it "proposes a consumer update against /consumers" do
      consumer_id = "cccccccc-cccc-cccc-cccc-cccccccccccc"
      stub_request(:get, "https://kong-admin.internal/consumers/#{consumer_id}")
        .to_return(status: 200, body: { id: consumer_id, username: "alice", tags: [] }.to_json)

      plan = planner(entity_type: "consumer", operation: "update", target_kong_id: consumer_id, attributes: { "tags" => [ "vip" ] }).call

      expect(plan.entity_type).to eq("consumer")
      expect(plan.after["tags"]).to eq([ "vip" ])
    end

    # Kong hands back a key-auth `key` in plaintext, and change_plans is not
    # exempt from PRODUCT.md's "secrets are redacted before ever being
    # written" constraint -- before/after are persisted and rendered on the
    # review page.
    it "never stores the plaintext credential Kong returned on the plan" do
      cred_id = "eeeeeeee-eeee-eeee-eeee-eeeeeeeeeeee"
      stub_request(:get, "https://kong-admin.internal/key-auths/#{cred_id}")
        .to_return(status: 200, body: { id: cred_id, key: "super-secret-key-123", tags: [] }.to_json)

      plan = planner(entity_type: "keyauth_credential", operation: "update", target_kong_id: cred_id,
        attributes: { "tags" => [ "rotated" ] }).call

      expect(plan.before["key"]).to eq("[REDACTED]")
      expect(plan.to_json).not_to include("super-secret-key-123")
    end

    it "never carries the redaction marker into `after`, so it can't be PATCHed back as the credential" do
      cred_id = "eeeeeeee-eeee-eeee-eeee-eeeeeeeeeeee"
      stub_request(:get, "https://kong-admin.internal/key-auths/#{cred_id}")
        .to_return(status: 200, body: { id: cred_id, key: "super-secret-key-123", tags: [] }.to_json)

      plan = planner(entity_type: "keyauth_credential", operation: "update", target_kong_id: cred_id,
        attributes: { "tags" => [ "rotated" ] }).call

      expect(plan.after).not_to have_key("key")
      expect(plan.after["tags"]).to eq([ "rotated" ])
    end

    it "still applies a genuinely new secret an API caller supplied" do
      cred_id = "eeeeeeee-eeee-eeee-eeee-eeeeeeeeeeee"
      stub_request(:get, "https://kong-admin.internal/key-auths/#{cred_id}")
        .to_return(status: 200, body: { id: cred_id, key: "super-secret-key-123", tags: [] }.to_json)

      plan = planner(entity_type: "keyauth_credential", operation: "update", target_kong_id: cred_id,
        attributes: { "key" => "a-rotated-key" }).call

      expect(plan.after["key"]).to eq("a-rotated-key")
    end

    it "carries parent_kong_id through on a credential create, for ChangeApplier's nested create path" do
      consumer_id = "cccccccc-cccc-cccc-cccc-cccccccccccc"

      plan = planner(entity_type: "keyauth_credential", operation: "create", parent_kong_id: consumer_id, attributes: { "key" => "s3cr3t" }).call

      expect(plan.parent_kong_id).to eq(consumer_id)
    end

    it "refuses to propose editing the plugin fronting this connection's own admin path, before ever creating a plan" do
      admin_route_id = "dddddddd-dddd-dddd-dddd-dddddddddddd"
      plugin_id = "eeeeeeee-eeee-eeee-eeee-eeeeeeeeeeee"
      connection.update!(admin_path_fingerprint: { "route_ids" => [ admin_route_id ], "plugin_ids" => [ plugin_id ] })

      expect {
        planner(entity_type: "plugin", operation: "update", target_kong_id: plugin_id, attributes: { "enabled" => false }).call
      }.to raise_error(Kong::ChangeGuardrails::Violation, /read-only/)
      expect(ChangePlan.count).to eq(0)
    end

    it "refuses to propose attaching a new plugin to the admin route itself" do
      admin_route_id = "dddddddd-dddd-dddd-dddd-dddddddddddd"
      connection.update!(admin_path_fingerprint: { "route_ids" => [ admin_route_id ] })

      expect {
        planner(entity_type: "plugin", operation: "create", attributes: { "name" => "rate-limiting", "route" => { "id" => admin_route_id } }).call
      }.to raise_error(Kong::ChangeGuardrails::Violation, /read-only/)
      expect(ChangePlan.count).to eq(0)
    end

    it "allows proposing a plugin change on an ordinary, non-admin-path target" do
      route_id = "ffffffff-ffff-ffff-ffff-ffffffffffff"
      plan = planner(entity_type: "plugin", operation: "create", attributes: { "name" => "cors", "route" => { "id" => route_id } }).call

      expect(plan).to be_persisted
      expect(plan.entity_type).to eq("plugin")
    end
  end
end
