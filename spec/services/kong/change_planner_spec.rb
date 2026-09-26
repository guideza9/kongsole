require "rails_helper"
require Rails.root.join("spec/support/pem_fixtures")

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

  describe "upstreams and targets (M5a)" do
    let(:upstream_id) { "aaaaaaaa-0000-0000-0000-00000000000a" }
    let(:target_id) { "cccccccc-0000-0000-0000-00000000000c" }
    let(:validate_upstream_url) { "https://kong-admin.internal/schemas/upstreams/validate" }
    let(:validate_target_url) { "https://kong-admin.internal/schemas/targets/validate" }
    let(:ok) { { status: 200, body: { message: "schema validation successful" }.to_json } }

    def upstream_planner(**overrides)
      planner(entity_type: "upstream", **overrides)
    end

    def target_planner(**overrides)
      planner(entity_type: "target", **overrides)
    end

    describe "upstream" do
      it "validates a new upstream against Kong's schema before proposing it" do
        validate = stub_request(:post, validate_upstream_url).to_return(ok)

        plan = upstream_planner(operation: "create", attributes: { "name" => "orders", "algorithm" => "round-robin" }).call

        expect(plan).to be_persisted
        expect(plan.entity_type).to eq("upstream")
        expect(plan.after).to eq({ "name" => "orders", "algorithm" => "round-robin" })
        expect(plan.parent_kong_id).to be_nil
        expect(validate.with(body: { "name" => "orders", "algorithm" => "round-robin" })).to have_been_requested
      end

      it "rejects a bad healthchecks block with Kong's per-field messages, and creates no plan" do
        stub_request(:post, validate_upstream_url).to_return(
          status: 400,
          body: { code: 2, name: "schema violation", message: "schema violation",
                  fields: { healthchecks: { active: { http_path: "should start with: /", healthy: { interval: "value should be between 0 and 65535" } } } } }.to_json
        )

        expect {
          upstream_planner(operation: "create", attributes: { "name" => "orders", "healthchecks" => { "active" => { "http_path" => "health" } } }).call
        }.to raise_error(Kong::ChangePlanner::SchemaViolation) { |e|
          expect(e).to be_a(Kong::ChangePlanner::InvalidChange)
          expect(e).to be_a(Kong::ChangeGuardrails::Violation) # existing rescues still catch it
          expect(e.message).to include("healthchecks.active.http_path: should start with: /")
          expect(e.message).to include("healthchecks.active.healthy.interval: value should be between 0 and 65535")
        }
        expect(ChangePlan.count).to eq(0)
      end

      it "falls back to Kong's message when a 400 carries no per-field detail" do
        stub_request(:post, validate_upstream_url).to_return(status: 400, body: { message: "bad body" }.to_json)

        expect {
          upstream_planner(operation: "create", attributes: { "name" => "orders" }).call
        }.to raise_error(Kong::ChangeGuardrails::Violation, /bad body/)
      end

      it "validates the merged document on update, without Kong-managed fields" do
        stub_request(:get, "https://kong-admin.internal/upstreams/#{upstream_id}")
          .to_return(status: 200, body: { id: upstream_id, name: "orders", algorithm: "round-robin", slots: 10_000,
                                          created_at: 1_700_000_000, updated_at: 1_700_000_100, tags: nil }.to_json)
        validate = stub_request(:post, validate_upstream_url).to_return(ok)

        plan = upstream_planner(operation: "update", target_kong_id: upstream_id, attributes: { "algorithm" => "least-connections" }).call

        expect(plan.diff).to eq({ "algorithm" => { "from" => "round-robin", "to" => "least-connections" } })
        expect(validate.with(body: { "name" => "orders", "algorithm" => "least-connections", "slots" => 10_000, "tags" => nil })).to have_been_requested
      end

      it "does not validate a delete" do
        stub_request(:get, "https://kong-admin.internal/upstreams/#{upstream_id}")
          .to_return(status: 200, body: { id: upstream_id, name: "orders" }.to_json)

        plan = upstream_planner(operation: "delete", target_kong_id: upstream_id).call

        expect(plan.diff).to eq({ "operation" => "delete" })
        expect(WebMock).not_to have_requested(:post, validate_upstream_url)
      end

      it "still refuses to propose on a read-only credential, before any Kong call" do
        connection.update!(access_level: "ro")

        expect {
          upstream_planner(operation: "create", attributes: { "name" => "orders" }).call
        }.to raise_error(Kong::ChangeGuardrails::Violation, /can't write/) { |e|
          expect(e).not_to be_a(Kong::ChangePlanner::SchemaViolation)
        }
        expect(WebMock).not_to have_requested(:post, validate_upstream_url)
      end
    end

    describe "target" do
      it "creates under its upstream, carries parent_kong_id on the plan, and validates with the upstream reference" do
        validate = stub_request(:post, validate_target_url).to_return(ok)

        plan = target_planner(operation: "create", parent_kong_id: upstream_id,
          attributes: { "target" => "10.0.0.1:8080", "weight" => 100 }).call

        expect(plan.entity_type).to eq("target")
        expect(plan.parent_kong_id).to eq(upstream_id)
        expect(plan.after).to eq({ "target" => "10.0.0.1:8080", "weight" => 100 })
        expect(validate.with(body: { "target" => "10.0.0.1:8080", "weight" => 100, "upstream" => { "id" => upstream_id } })).to have_been_requested
      end

      it "refuses to create a target without an upstream" do
        expect {
          target_planner(operation: "create", attributes: { "target" => "10.0.0.1:8080" }).call
        }.to raise_error(Kong::ChangePlanner::MissingParent, /upstream/) { |e|
          expect(e).to be_a(Kong::ChangePlanner::InvalidChange) # a malformed request, not a guardrail
        }
        expect(ChangePlan.count).to eq(0)
      end

      it "rejects a malformed target with Kong's field message" do
        stub_request(:post, validate_target_url).to_return(
          status: 400, body: { name: "schema violation", message: "schema violation", fields: { target: "Invalid target; ..." } }.to_json
        )

        expect {
          target_planner(operation: "create", parent_kong_id: upstream_id, attributes: { "target" => "not a target" }).call
        }.to raise_error(Kong::ChangeGuardrails::Violation, /target: Invalid target/)
      end

      it "resolves the upstream of an existing target from the read-model, and fetches through the nested path" do
        create(:kong_entity, kong_connection: connection, entity_type: "target", kong_id: target_id,
          name: "10.0.0.1:8080", parent_type: "upstream", parent_kong_id: upstream_id)
        get = stub_request(:get, "https://kong-admin.internal/upstreams/#{upstream_id}/targets/#{target_id}")
          .to_return(status: 200, body: { id: target_id, target: "10.0.0.1:8080", weight: 100,
                                          upstream: { id: upstream_id }, created_at: 1_700_000_000.226, updated_at: 1_700_000_100.5 }.to_json)
        validate = stub_request(:post, validate_target_url).to_return(ok)

        plan = target_planner(operation: "update", target_kong_id: target_id, attributes: { "weight" => 50 }).call

        expect(get).to have_been_requested
        expect(plan.parent_kong_id).to eq(upstream_id)
        expect(plan.diff).to eq({ "weight" => { "from" => 100, "to" => 50 } })
        expect(validate.with(body: { "target" => "10.0.0.1:8080", "weight" => 50, "upstream" => { "id" => upstream_id } })).to have_been_requested
      end

      it "prefers an explicitly supplied parent over the read-model lookup" do
        get = stub_request(:get, "https://kong-admin.internal/upstreams/#{upstream_id}/targets/#{target_id}")
          .to_return(status: 200, body: { id: target_id, target: "10.0.0.1:8080", weight: 100, upstream: { id: upstream_id } }.to_json)

        plan = target_planner(operation: "delete", target_kong_id: target_id, parent_kong_id: upstream_id).call

        expect(get).to have_been_requested
        expect(plan.parent_kong_id).to eq(upstream_id)
        expect(plan.diff).to eq({ "operation" => "delete" })
      end

      it "refuses to update a target whose upstream can't be determined, without calling Kong" do
        expect {
          target_planner(operation: "update", target_kong_id: target_id, attributes: { "weight" => 50 }).call
        }.to raise_error(Kong::ChangePlanner::MissingParent, /upstream.*sync/i)
        expect(WebMock).not_to have_requested(:any, /kong-admin/)
      end
    end
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

    # R4.5: Kong's own schema checks a new plugin, as it does an upstream.
    it "refuses a new plugin Kong's schema rejects, with Kong's field message" do
      stub_request(:post, "https://kong-admin.internal/schemas/plugins/validate")
        .to_return(status: 400, body: { fields: { config: { minute: "expected a number" } } }.to_json)
      expect { planner(entity_type: "plugin", operation: "create", attributes: { "name" => "rate-limiting", "config" => { "minute" => "x" } }).call }
        .to raise_error(described_class::SchemaViolation, /config\.minute: expected a number/)
    end

    # An update's body has the redacted secrets pruned out, and Kong would
    # call a required one missing though it still holds it.
    it "does not ask Kong's schema about a plugin update" do
      plugin_id = SecureRandom.uuid
      live = { "id" => plugin_id, "name" => "aws-lambda", "config" => { "aws_key" => "AKIA" }, "updated_at" => 1 }
      stub_request(:get, "https://kong-admin.internal/plugins/#{plugin_id}").to_return(status: 200, body: live.to_json)
      stub_request(:get, "https://kong-admin.internal/schemas/plugins/aws-lambda").to_return(status: 200, body: { fields: [] }.to_json)
      plan = planner(entity_type: "plugin", operation: "update", target_kong_id: plugin_id, attributes: { "enabled" => false }).call
      expect(plan).to be_persisted
      expect(a_request(:post, %r{/schemas/plugins/validate})).not_to have_been_made
    end

    # R4.10: a direct-mode plugin's secret never sits in the plan in the clear.
    describe "sealing a plugin's secrets (direct mode)" do
      let(:lambda_schema) do
        { fields: [ { config: { type: "record", fields: [
          { aws_secret: { type: "string", encrypted: true, referenceable: true } }, { function_name: { type: "string" } } ] } } ] }.to_json
      end

      before do
        stub_request(:get, "https://kong-admin.internal/schemas/plugins/aws-lambda").to_return(status: 200, body: lambda_schema)
        stub_request(:post, "https://kong-admin.internal/schemas/plugins/validate").to_return(status: 200, body: "{}")
      end

      it "stores a new plugin's secret redacted, with the real value sealed" do
        plan = planner(entity_type: "plugin", operation: "create",
          attributes: { "name" => "aws-lambda", "config" => { "aws_secret" => "sk_PLAIN", "function_name" => "f" } }).call
        expect(plan.after.to_json).not_to include("sk_PLAIN")
        expect(plan.after.dig("config", "aws_secret")).to eq(Kong::Redactor::MARK)
        expect(plan.unsealed_after.dig("config", "aws_secret")).to eq("sk_PLAIN")
        expect(ChangePlan.connection.select_value("SELECT sealed_secrets FROM change_plans WHERE id = #{plan.id}")).not_to include("sk_PLAIN")
      end

      it "stores an update's changed secret redacted on both sides of the diff" do
        plugin_id = SecureRandom.uuid
        live = { "id" => plugin_id, "name" => "aws-lambda", "config" => { "aws_secret" => "old", "function_name" => "f" }, "updated_at" => 1 }
        stub_request(:get, "https://kong-admin.internal/plugins/#{plugin_id}").to_return(status: 200, body: live.to_json)
        plan = planner(entity_type: "plugin", operation: "update", target_kong_id: plugin_id,
          attributes: { "config" => { "aws_secret" => "sk_NEW", "function_name" => "f" } }).call
        expect(plan.diff.to_json).not_to include("sk_NEW")
        expect(plan.unsealed_diff.dig("config", "to", "aws_secret")).to eq("sk_NEW")
      end

      # Owner's call (2026-09-26): where sealing cannot work -- no Active
      # Record encryption keys on this machine -- keep plain text, as before.
      it "keeps the plain value, and proposes anyway, where no encryption keys are set" do
        allow(ActiveRecord::Encryption.config).to receive(:primary_key)
          .and_raise(ActiveRecord::Encryption::Errors::Configuration, "Missing Active Record encryption credential")
        plan = planner(entity_type: "plugin", operation: "create",
          attributes: { "name" => "aws-lambda", "config" => { "aws_secret" => "sk_PLAIN", "function_name" => "f" } }).call
        expect(plan.after.dig("config", "aws_secret")).to eq("sk_PLAIN")
        expect(plan.sealed_secrets).to be_nil
      end

      it "clears the seal of this connection's plans that expired unapplied" do
        stale = create(:change_plan, kong_connection: connection, entity_type: "plugin", expires_at: 1.minute.ago,
          sealed_secrets: { "after" => { "config" => { "aws_secret" => "x" } } }.to_json)
        planner(entity_type: "plugin", operation: "create", attributes: { "name" => "aws-lambda", "config" => {} }).call
        expect(stale.reload.sealed_secrets).to be_nil
      end
    end

    it "allows proposing a plugin change on an ordinary, non-admin-path target" do
      route_id = "ffffffff-ffff-ffff-ffff-ffffffffffff"
      stub_request(:post, "https://kong-admin.internal/schemas/plugins/validate").to_return(status: 200, body: "{}")
      stub_request(:get, "https://kong-admin.internal/schemas/plugins/cors").to_return(status: 200, body: { fields: [] }.to_json)
      plan = planner(entity_type: "plugin", operation: "create", attributes: { "name" => "cors", "route" => { "id" => route_id } }).call

      expect(plan).to be_persisted
      expect(plan.entity_type).to eq("plugin")
    end
  end

  describe "certificates and SNIs (M5b)" do
    let(:cert_id) { "dddddddd-0000-0000-0000-00000000000d" }
    let(:pem) { PemFixtures.self_signed(days: 60)[:cert_pem] }
    let(:ok) { { status: 200, body: { message: "schema validation successful" }.to_json } }
    let(:validate_certs) { "https://kong-admin.internal/schemas/certificates/validate" }
    let(:validate_snis) { "https://kong-admin.internal/schemas/snis/validate" }

    def cert_planner(**overrides)
      planner(entity_type: "certificate", **overrides)
    end

    describe "certificate key policy" do
      it "proposes a create whose key is a vault reference, validating it with Kong" do
        validate = stub_request(:post, validate_certs).to_return(ok)

        plan = cert_planner(operation: "create",
          attributes: { "cert" => pem, "key" => "{vault://env/cert-pay-key}", "snis" => [ "pay.example.internal" ] }).call

        expect(plan).to be_persisted
        expect(plan.after["key"]).to eq("{vault://env/cert-pay-key}")
        expect(validate.with(body: hash_including("key" => "{vault://env/cert-pay-key}"))).to have_been_requested
      end

      it "keeps snis in the plan but never sends it to Kong's schema validation (not a schema field on a real Kong)" do
        validate = stub_request(:post, validate_certs).to_return(ok)

        plan = cert_planner(operation: "create",
          attributes: { "cert" => pem, "key" => "{vault://env/cert-pay-key}", "snis" => [ "pay.example.internal" ] }).call

        expect(plan.after["snis"]).to eq([ "pay.example.internal" ])
        expect(validate.with { |req| !JSON.parse(req.body).key?("snis") }).to have_been_requested
      end

      it "also omits the live snis from the validation body on an update, while after keeps them" do
        stub_request(:get, "https://kong-admin.internal/certificates/#{cert_id}").to_return(status: 200, body: {
          id: cert_id, cert: pem, key: "{vault://env/cert-pay-key}", snis: [ "pay.example.internal" ], tags: [], updated_at: 1_700_000_000
        }.to_json)
        validate = stub_request(:post, validate_certs).to_return(ok)

        plan = cert_planner(operation: "update", target_kong_id: cert_id, attributes: { "tags" => [ "core" ] }).call

        expect(plan.after["snis"]).to eq([ "pay.example.internal" ])
        expect(validate.with { |req| !JSON.parse(req.body).key?("snis") }).to have_been_requested
      end

      it "rejects a PEM key before any request reaches Kong, never persisting or echoing it" do
        pem_key = PemFixtures.self_signed[:key_pem]

        expect {
          cert_planner(operation: "create", attributes: { "cert" => pem, "key" => pem_key }).call
        }.to raise_error(Kong::CertificateKeyPolicy::Rejected) { |e|
          expect(e).to be_a(Kong::ChangePlanner::InvalidChange)
          expect(e.message).not_to include("PRIVATE KEY")
        }
        expect(ChangePlan.count).to eq(0)
        expect(WebMock).not_to have_requested(:any, /kong-admin/)
      end

      it "rejects a create with no key at all" do
        expect {
          cert_planner(operation: "create", attributes: { "cert" => pem }).call
        }.to raise_error(Kong::CertificateKeyPolicy::Rejected, /needs a key/)
      end

      it "rejects a decK placeholder on a direct-mode connection" do
        expect {
          cert_planner(operation: "create", attributes: { "cert" => pem, "key" => '${{ env "DECK_CERT_A" }}' }).call
        }.to raise_error(Kong::CertificateKeyPolicy::Rejected, /direct/)
      end

      it "rejects a PEM smuggled into key_alt on update, too" do
        expect {
          cert_planner(operation: "update", target_kong_id: cert_id,
            attributes: { "key_alt" => "-----BEGIN PRIVATE KEY-----\nA\n-----END PRIVATE KEY-----" }).call
        }.to raise_error(Kong::CertificateKeyPolicy::Rejected, /key_alt/)
        expect(WebMock).not_to have_requested(:any, /kong-admin/)
      end

      it "proposes a tags-only update without touching key policy, keeping the live reference readable" do
        stub_request(:get, "https://kong-admin.internal/certificates/#{cert_id}").to_return(status: 200, body: {
          id: cert_id, cert: pem, key: "{vault://env/cert-pay-key}", snis: [ "pay.example.internal" ], tags: [], updated_at: 1_700_000_000
        }.to_json)
        stub_request(:post, validate_certs).to_return(ok)

        plan = cert_planner(operation: "update", target_kong_id: cert_id, attributes: { "tags" => [ "core" ] }).call

        expect(plan.diff).to eq({ "tags" => { "from" => [], "to" => [ "core" ] } })
        expect(plan.before["key"]).to eq("{vault://env/cert-pay-key}")
      end

      it "redacts a plaintext key Kong hands back and never carries it into after" do
        stub_request(:get, "https://kong-admin.internal/certificates/#{cert_id}").to_return(status: 200, body: {
          id: cert_id, cert: pem, key: "-----BEGIN PRIVATE KEY-----\nLEGACY\n-----END PRIVATE KEY-----", snis: [], tags: [], updated_at: 1_700_000_000
        }.to_json)
        stub_request(:post, validate_certs).to_return(ok)

        plan = cert_planner(operation: "update", target_kong_id: cert_id, attributes: { "tags" => [ "x" ] }).call

        expect(plan.before["key"]).to eq("[REDACTED]")
        expect(plan.after).not_to have_key("key")
        expect(plan.to_json).not_to include("LEGACY")
      end
    end

    describe "a private key nested under another field" do
      it "is rejected on a PR-mode connection (where Kong's schema check is skipped), with no plan created" do
        set_env_policy(connection, apply_mode: "pr").update!(access_level: "ro")
        pem_key = PemFixtures.self_signed[:key_pem]

        expect {
          cert_planner(operation: "create",
            attributes: { "cert" => pem, "key" => '${{ env "DECK_CERT_A" }}', "foo" => { "key" => pem_key } }).call
        }.to raise_error(Kong::CertificateKeyPolicy::Rejected, /foo\.key/) { |e|
          expect(e.message).not_to include("PRIVATE KEY")
        }
        expect(ChangePlan.count).to eq(0)
        expect(WebMock).not_to have_requested(:any, /kong-admin/)
      end
    end

    describe "PR-mode connections" do
      it "accepts a decK placeholder and makes no schema POST (a read-only route would 404 it)" do
        set_env_policy(connection, apply_mode: "pr").update!(access_level: "ro")

        plan = cert_planner(operation: "create", attributes: { "cert" => pem, "key" => '${{ env "DECK_CERT_A" }}' }).call

        expect(plan.apply_mode).to eq("pr")
        expect(plan.after["key"]).to eq('${{ env "DECK_CERT_A" }}')
        expect(WebMock).not_to have_requested(:any, /kong-admin/)
      end

      it "skips the schema POST for the M5a types too -- upstreams and targets in PR mode" do
        set_env_policy(connection, apply_mode: "pr").update!(access_level: "ro")

        plan = planner(entity_type: "upstream", operation: "create", attributes: { "name" => "orders" }).call

        expect(plan).to be_persisted
        expect(WebMock).not_to have_requested(:post, /schemas/)
      end
    end

    describe "sni" do
      def sni_planner(**overrides)
        planner(entity_type: "sni", **overrides)
      end

      it "requires a certificate on create" do
        expect {
          sni_planner(operation: "create", attributes: { "name" => "pay.example.internal" }).call
        }.to raise_error(Kong::ChangePlanner::MissingParent, /certificate/)
        expect(ChangePlan.count).to eq(0)
      end

      it "rejects a private key hidden in an SNI payload -- also on a PR-mode connection, where Kong's schema check is skipped" do
        pem_key = "-----BEGIN PRIVATE KEY-----\nSNIKEYSENTINEL0123\n-----END PRIVATE KEY-----\n"
        [ "direct", "pr" ].each do |mode|
          connection.update!(apply_mode: mode)
          [ { "name" => "a.example", "extra" => { "k" => pem_key } }, { "name" => "a.example", "extra" => { pem_key => 1 } } ].each do |attrs|
            expect { sni_planner(operation: "create", parent_kong_id: cert_id, attributes: attrs).call }
              .to raise_error(Kong::CertificateKeyPolicy::Rejected) { |e| expect(e.message).not_to include("SNIKEYSENTINEL") }
          end
        end
        expect(ChangePlan.count).to eq(0)
      end

      it "carries the certificate reference in the create body, and validates with it" do
        validate = stub_request(:post, validate_snis).to_return(ok)

        plan = sni_planner(operation: "create", parent_kong_id: cert_id, attributes: { "name" => "pay.example.internal" }).call

        expect(plan.after).to eq({ "name" => "pay.example.internal", "certificate" => { "id" => cert_id } })
        expect(plan.parent_kong_id).to eq(cert_id)
        expect(validate.with(body: { "name" => "pay.example.internal", "certificate" => { "id" => cert_id } })).to have_been_requested
      end

      it "plans an SNI delete without needing the parent for any path, but records it from the read-model when known" do
        sni_id = "eeeeeeee-0000-0000-0000-00000000000e"
        create(:kong_entity, kong_connection: connection, entity_type: "sni", kong_id: sni_id, name: "pay.example.internal",
          parent_type: "certificate", parent_kong_id: cert_id)
        stub_request(:get, "https://kong-admin.internal/snis/#{sni_id}")
          .to_return(status: 200, body: { id: sni_id, name: "pay.example.internal", certificate: { id: cert_id }, updated_at: 1_700_000_000 }.to_json)

        plan = sni_planner(operation: "delete", target_kong_id: sni_id).call

        expect(plan.parent_kong_id).to eq(cert_id)
      end

      it "still plans an SNI delete when the read-model has never seen it (parent unknown is fine for a flat child)" do
        sni_id = "eeeeeeee-0000-0000-0000-00000000000e"
        stub_request(:get, "https://kong-admin.internal/snis/#{sni_id}")
          .to_return(status: 200, body: { id: sni_id, name: "x.example", certificate: { id: cert_id }, updated_at: 1_700_000_000 }.to_json)

        plan = sni_planner(operation: "delete", target_kong_id: sni_id).call

        expect(plan).to be_persisted
        expect(plan.parent_kong_id).to be_nil
      end
    end

    it "plans a CA certificate create, validated, with no key policy involved" do
      validate = stub_request(:post, "https://kong-admin.internal/schemas/ca_certificates/validate").to_return(ok)

      plan = planner(entity_type: "ca_certificate", operation: "create", attributes: { "cert" => pem }).call

      expect(plan).to be_persisted
      expect(validate).to have_been_requested
    end
  end

  # R8.2: every PR-mode proposal collects in the connection's open changeset.
  describe "PR mode" do
    let(:env) { create(:project_env, name: "uat", apply_mode: "pr", source: "registry", select_tags: %w[managed-by-kongctl]) }
    let(:connection) { create(:kong_connection, project_env: env, access_level: "ro", admin_url: "https://kong.test") }
    let(:client) { Kong::Client.new(connection: connection, secret: "pw") }

    def plan_create(name)
      described_class.new(connection: connection, client: client, operation: "create", entity_type: "service",
        actor_username: "alice", attributes: { "name" => name, "url" => "http://#{name}.internal" }).call
    end

    # R4.4: every path into a PR-mode plugin (the form, the JSON editor, MCP)
    # goes through the planner, so the secret policy lives here.
    describe "plugin secrets" do
      let(:schema) { File.read(Rails.root.join("spec/fixtures/schemas/rate_limiting_like.json")) }

      def plan_plugin(operation: "create", **attributes)
        described_class.new(connection: connection, client: client, operation: operation, entity_type: "plugin",
          actor_username: "alice", **attributes).call
      end

      before { stub_request(:get, "https://kong.test/schemas/plugins/rate-limiting").to_return(status: 200, body: schema) }

      it "refuses a plaintext secret, naming the field and not the value" do
        expect { plan_plugin(attributes: { "name" => "rate-limiting", "config" => { "api_key" => "sk_live_1" } }) }
          .to raise_error(described_class::InvalidChange, /config\.api_key/) { |e| expect(e.message).not_to include("sk_live_1") }
        expect(ChangePlan.count).to eq(0)
      end

      it "takes a vault reference into the changeset" do
        plan = plan_plugin(attributes: { "name" => "rate-limiting", "config" => { "api_key" => "{vault://env/rl-api-key}" } })
        expect(plan.changeset).to be_present
        expect(plan.after.dig("config", "api_key")).to eq("{vault://env/rl-api-key}")
      end

      it "checks an update against the plugin's name on Kong" do
        plugin_id = SecureRandom.uuid
        live = { "id" => plugin_id, "name" => "rate-limiting", "config" => { "api_key" => nil }, "updated_at" => 1 }
        stub_request(:get, "https://kong.test/plugins/#{plugin_id}").to_return(status: 200, body: live.to_json)
        expect { plan_plugin(operation: "update", target_kong_id: plugin_id, attributes: { "config" => { "api_key" => "plain" } }) }
          .to raise_error(described_class::InvalidChange, /config\.api_key/)
      end

      # R4 final review: PR mode skips Kong's validation, so a key the schema
      # does not have (a typo) is never checked as a secret -- refuse it.
      it "refuses a config key the plugin's schema does not have, at any record depth, without echoing it" do
        expect { plan_plugin(attributes: { "name" => "rate-limiting", "config" => { "apikey" => "sk_live_PLAIN" } }) }
          .to raise_error(described_class::InvalidChange, /config\.apikey/) { |e| expect(e.message).not_to include("sk_live_PLAIN") }
        expect { plan_plugin(attributes: { "name" => "rate-limiting", "config" => { "redis" => { "passwrd" => "hunter2" } } }) }
          .to raise_error(described_class::InvalidChange, /config\.redis\.passwrd/)
        expect(ChangePlan.count).to eq(0)
      end

      it "checks an update against the live plugin's name, not one the update sends" do
        plugin_id = SecureRandom.uuid
        live = { "id" => plugin_id, "name" => "rate-limiting", "config" => {}, "updated_at" => 1 }
        stub_request(:get, "https://kong.test/plugins/#{plugin_id}").to_return(status: 200, body: live.to_json)
        stub_request(:get, "https://kong.test/schemas/plugins/file-log").to_return(status: 200, body: { fields: [] }.to_json)
        expect { plan_plugin(operation: "update", target_kong_id: plugin_id, attributes: { "name" => "file-log", "config" => { "api_key" => "plain" } }) }
          .to raise_error(described_class::InvalidChange, /config\.api_key/)
      end

      it "refuses when Kong's schema for the plugin cannot be read" do
        stub_request(:get, "https://kong.test/schemas/plugins/rate-limiting").to_return(status: 503, body: "{}")
        expect { plan_plugin(attributes: { "name" => "rate-limiting", "config" => {} }) }
          .to raise_error(described_class::InvalidChange, /schema/)
      end
    end

    it "puts every plan into the connection's open changeset, in order, and makes no write call" do
      a = plan_create("billing")
      b = plan_create("ledger")
      expect(a.changeset).to eq(b.changeset)
      expect([ a.position, b.position ]).to eq([ 1, 2 ])
      expect(a.provisional_kong_id).to be_present
      expect(a_request(:any, /kong\.test/).with { |req| req.method != :get }).not_to have_been_made
    end

    it "refuses a second item on the same entity unless it replaces the first" do
      live = { "id" => SecureRandom.uuid, "name" => "billing", "tags" => [], "updated_at" => 1 }
      stub_request(:get, "https://kong.test/services/#{live['id']}").to_return(status: 200, body: live.to_json)
      first = described_class.new(connection: connection, client: client, operation: "update", entity_type: "service",
        target_kong_id: live["id"], actor_username: "a", attributes: { "tags" => %w[x] }).call
      expect {
        described_class.new(connection: connection, client: client, operation: "update", entity_type: "service",
          target_kong_id: live["id"], actor_username: "a", attributes: { "tags" => %w[y] }).call
      }.to raise_error(Kong::ChangePlanner::InvalidChange, /already in this changeset/)

      replacement = described_class.new(connection: connection, client: client, operation: "update", entity_type: "service",
        target_kong_id: live["id"], actor_username: "a", attributes: { "tags" => %w[y] }, replaces_plan_id: first.id).call
      expect(first.reload.status).to eq("cancelled")
      expect(replacement.position).to eq(first.position)
    end

    it "keeps a replaced create's provisional id, so its children still find it" do
      first = plan_create("billing")
      replacement = described_class.new(connection: connection, client: client, operation: "create", entity_type: "service",
        actor_username: "alice", attributes: { "name" => "billing", "url" => "http://billing-v2.internal" }, replaces_plan_id: first.id).call
      expect(replacement.provisional_kong_id).to eq(first.provisional_kong_id)
    end

    it "refuses to replace a plan that is not a pending item of this changeset" do
      other = create(:change_plan, kong_connection: connection, apply_mode: "pr", status: "applied")
      expect { plan_create_replacing(other.id) }.to raise_error(Kong::ChangePlanner::InvalidChange, /not an item/)
    end

    def plan_create_replacing(id)
      described_class.new(connection: connection, client: client, operation: "create", entity_type: "service",
        actor_username: "alice", attributes: { "name" => "x", "url" => "http://x.internal" }, replaces_plan_id: id).call
    end

    # Final review #2: a submit or abandon that finished between finding the
    # changeset and adding to it leaves the item in a fresh open one.
    it "adds to a fresh changeset when the one it found closed in the meantime" do
      first = plan_create("billing").changeset
      calls = 0
      allow(Changeset).to receive(:open_for!).and_wrap_original do |m, **kw|
        found = m.call(**kw)
        Changeset.where(id: found.id).update_all(status: "submitted") if (calls += 1) == 1
        found
      end

      later = plan_create("ledger")

      expect(later.changeset).not_to eq(first)
      expect(later.changeset).to be_open
      expect(first.reload.change_plans.pending.pluck(:id)).not_to include(later.id)
    end

    # Final review #9: reading the config repo's head is network I/O; it must
    # not hold a database transaction open while it waits.
    it "reads the config repo's head outside any database transaction" do
      baseline = ActiveRecord::Base.connection.open_transactions
      seen = nil
      allow_any_instance_of(Kong::GitClient).to receive(:remote_head_sha) { seen = ActiveRecord::Base.connection.open_transactions; "a" * 40 }
      connection.update_columns(git_repo: "/some/repo.git")
      plan_create("billing")
      expect(seen).to eq(baseline)
    end

    it "refuses an admin-path entity before it reaches the changeset" do
      admin_id = SecureRandom.uuid
      connection.update!(admin_path_fingerprint: { "service_id" => admin_id, "route_ids" => [], "plugin_ids" => [], "consumer_ids" => [] })
      stub_request(:get, "https://kong.test/services/#{admin_id}")
        .to_return(status: 200, body: { id: admin_id, name: "admin-api", tags: %w[kong-admin-path], updated_at: 1 }.to_json)

      expect {
        described_class.new(connection: connection, client: client, operation: "update", entity_type: "service",
          target_kong_id: admin_id, actor_username: "a", attributes: { "tags" => %w[x] }).call
      }.to raise_error(Kong::ChangePlanner::InvalidChange, /admin-path/)
      expect(Changeset.count).to eq(0)
    end
  end

  # R2.4: every create carries the connection's select_tags, whoever proposes
  # it -- a form, the JSON editor or an agent -- so decK's select_tags scope
  # (and `deck gateway sync`) always sees it.
  describe "select_tags on create" do
    let(:env) { create(:project_env, name: "uat", apply_mode: "pr", source: "registry", select_tags: %w[managed-by-kongctl]) }
    let(:pr_connection) { create(:kong_connection, project_env: env, access_level: "ro", admin_url: "https://kong.test") }

    it "adds them to an agent's create, ahead of its own tags and without duplicates" do
      plan = described_class.new(connection: pr_connection, client: Kong::Client.new(connection: pr_connection, secret: "pw"),
        operation: "create", entity_type: "service", actor_username: "alice", actor_kind: "agent",
        attributes: { "name" => "billing", "url" => "http://billing.internal", "tags" => %w[team-a managed-by-kongctl] }).call
      expect(plan.after["tags"]).to eq(%w[managed-by-kongctl team-a])
    end

    it "adds them in direct mode too" do
      connection.project_env.update!(select_tags: %w[team-a])
      connection.save! # the connection copies its env's select_tags
      stub_request(:post, "https://kong-admin.internal/schemas/services/validate").to_return(status: 200, body: "{}")
      plan = planner(operation: "create", attributes: { "name" => "billing", "url" => "http://billing.internal" }).call
      expect(plan.after["tags"]).to eq(%w[team-a])
    end

    it "leaves an update's tags as the operator set them" do
      connection.project_env.update!(select_tags: %w[team-a])
      connection.save! # the connection copies its env's select_tags
      live = { "id" => PLANNER_SVC_1, "name" => "billing", "tags" => [], "updated_at" => 1 }
      stub_request(:get, "https://kong-admin.internal/services/#{PLANNER_SVC_1}").to_return(status: 200, body: live.to_json)
      stub_request(:post, "https://kong-admin.internal/schemas/services/validate").to_return(status: 200, body: "{}")
      plan = planner(operation: "update", target_kong_id: PLANNER_SVC_1, attributes: { "tags" => %w[x] }).call
      expect(plan.after["tags"]).to eq(%w[x])
    end
  end
end
