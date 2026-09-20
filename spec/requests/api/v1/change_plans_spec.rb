require "rails_helper"
require Rails.root.join("spec/support/pem_fixtures")

RSpec.describe "API::V1::ChangePlans", type: :request do
  def auth(raw_token)
    { "Authorization" => "Bearer #{raw_token}" }
  end

  def token_for(*connections)
    _pat, raw = PersonalAccessToken.issue!(operator: "alice", issued_by_username: "alice", connection_ids: connections.map(&:id))
    raw
  end

  describe "POST /api/v1/change_plans (kong_plan)" do
    it "proposes an update and returns the diff + plan id" do
      connection = create(:kong_connection, admin_url: "https://kong-admin.test", access_level: "rw", credential_mode: "stored", auth_secret: "devpassword")
      token = token_for(connection)
      kong_id = "11111111-1111-1111-1111-111111111111"
      stub_request(:get, "https://kong-admin.test/services/#{kong_id}")
        .to_return(status: 200, body: { id: kong_id, name: "payments-webhook", tags: [ "payment" ] }.to_json)

      post api_v1_change_plans_path, params: {
        connection: connection.name, type: "service", operation: "update",
        target_kong_id: kong_id, attributes: { tags: %w[payment deprecated] }
      }, headers: auth(token)

      expect(response).to have_http_status(:created)
      json = JSON.parse(response.body)
      expect(json["diff"]).to include("tags")
      expect(json["status"]).to eq("pending")
      expect(ChangePlan.find(json["id"]).actor_kind).to eq("agent")
      expect(ChangePlan.find(json["id"]).actor_operator).to eq("alice")
    end

    it "returns 403 without creating a plan when the credential can't write" do
      connection = create(:kong_connection, admin_url: "https://kong-admin.test", access_level: "ro", credential_mode: "stored", auth_secret: "devpassword")
      token = token_for(connection)

      post api_v1_change_plans_path, params: {
        connection: connection.name, type: "service", operation: "update",
        target_kong_id: "11111111-1111-1111-1111-111111111111", attributes: { tags: [ "x" ] }
      }, headers: auth(token)

      expect(response).to have_http_status(:forbidden)
      expect(ChangePlan.count).to eq(0)
    end

    it "returns 403 and creates no plan for a delete of an admin-path entity, with no override possible" do
      kong_id = "aaaaaaaa-aaaa-aaaa-aaaa-aaaaaaaaaaaa"
      connection = create(:kong_connection, admin_url: "https://kong-admin.test", access_level: "rw", credential_mode: "stored",
        auth_secret: "devpassword", admin_path_fingerprint: { "service_id" => kong_id })
      token = token_for(connection)
      stub_request(:get, "https://kong-admin.test/services/#{kong_id}")
        .to_return(status: 200, body: { id: kong_id, name: "admin-api", tags: [] }.to_json)

      post api_v1_change_plans_path, params: {
        connection: connection.name, type: "service", operation: "delete", target_kong_id: kong_id,
        confirmation_name: "admin-api" # even an explicit (correct!) confirmation does not help an agent
      }, headers: auth(token)

      expect(response).to have_http_status(:forbidden)
      expect(response.body).to include("no override")
      expect(ChangePlan.count).to eq(0)
    end

    it "returns 401 when the connection isn't bound to this token" do
      connection = create(:kong_connection, credential_mode: "stored")
      other = create(:kong_connection, name: "other", credential_mode: "stored")
      token = token_for(other)

      post api_v1_change_plans_path, params: { connection: connection.name, type: "service", operation: "update" }, headers: auth(token)

      expect(response).to have_http_status(:unauthorized)
    end

    it "proposes a route update against /routes" do
      connection = create(:kong_connection, admin_url: "https://kong-admin.test", access_level: "rw", credential_mode: "stored", auth_secret: "devpassword")
      token = token_for(connection)
      route_id = "33333333-3333-3333-3333-333333333333"
      stub_request(:get, "https://kong-admin.test/routes/#{route_id}")
        .to_return(status: 200, body: { id: route_id, name: "charge", tags: [] }.to_json)

      post api_v1_change_plans_path, params: {
        connection: connection.name, type: "route", operation: "update",
        target_kong_id: route_id, attributes: { tags: [ "beta" ] }
      }, headers: auth(token)

      expect(response).to have_http_status(:created)
      expect(JSON.parse(response.body)["entity_type"]).to eq("route")
    end

    it "proposes a keyauth_credential create, carrying parent_kong_id through to the plan" do
      connection = create(:kong_connection, admin_url: "https://kong-admin.test", access_level: "rw", credential_mode: "stored", auth_secret: "devpassword")
      token = token_for(connection)
      consumer_id = "cccccccc-cccc-cccc-cccc-cccccccccccc"

      post api_v1_change_plans_path, params: {
        connection: connection.name, type: "keyauth_credential", operation: "create", parent_kong_id: consumer_id
      }, headers: auth(token)

      expect(response).to have_http_status(:created)
      json = JSON.parse(response.body)
      expect(ChangePlan.find(json["id"]).parent_kong_id).to eq(consumer_id)
    end

    it "rejects an unsupported type" do
      connection = create(:kong_connection, credential_mode: "stored")
      token = token_for(connection)

      post api_v1_change_plans_path, params: { connection: connection.name, type: "widget", operation: "update" }, headers: auth(token)

      expect(response).to have_http_status(:bad_request)
      expect(response.body).to include("upstream").and include("target")
      expect(ChangePlan.count).to eq(0)
    end

    describe "upstreams and targets (M5a)" do
      let(:connection) { create(:kong_connection, admin_url: "https://kong-admin.test", access_level: "rw", credential_mode: "stored", auth_secret: "devpassword") }
      let(:token) { token_for(connection) }
      let(:upstream_id) { "aaaaaaaa-0000-0000-0000-00000000000a" }
      let(:target_id) { "cccccccc-0000-0000-0000-00000000000c" }
      let(:ok) { { status: 200, body: { message: "schema validation successful" }.to_json } }

      it "proposes an upstream create, validated against Kong's schema first" do
        validate = stub_request(:post, "https://kong-admin.test/schemas/upstreams/validate").to_return(ok)

        post api_v1_change_plans_path, params: {
          connection: connection.name, type: "upstream", operation: "create",
          attributes: { name: "orders", algorithm: "round-robin" }
        }, headers: auth(token)

        expect(response).to have_http_status(:created)
        json = JSON.parse(response.body)
        expect(json["entity_type"]).to eq("upstream")
        expect(ChangePlan.find(json["id"]).after).to eq({ "name" => "orders", "algorithm" => "round-robin" })
        expect(validate).to have_been_requested
      end

      it "proposes a target create under its upstream and reports the parent back" do
        stub_request(:post, "https://kong-admin.test/schemas/targets/validate").to_return(ok)

        post api_v1_change_plans_path, params: {
          connection: connection.name, type: "target", operation: "create", parent_kong_id: upstream_id,
          attributes: { target: "10.0.0.1:8080", weight: 100 }
        }, headers: auth(token)

        expect(response).to have_http_status(:created)
        json = JSON.parse(response.body)
        expect(json["parent_kong_id"]).to eq(upstream_id)
        expect(ChangePlan.find(json["id"]).parent_kong_id).to eq(upstream_id)
      end

      it "resolves the upstream of an existing target from the read-model, so an agent only needs the target id" do
        create(:kong_entity, kong_connection: connection, entity_type: "target", kong_id: target_id, name: "10.0.0.1:8080",
          parent_type: "upstream", parent_kong_id: upstream_id)
        stub_request(:get, "https://kong-admin.test/upstreams/#{upstream_id}/targets/#{target_id}")
          .to_return(status: 200, body: { id: target_id, target: "10.0.0.1:8080", weight: 100, upstream: { id: upstream_id }, updated_at: 1_700_000_000 }.to_json)
        stub_request(:post, "https://kong-admin.test/schemas/targets/validate").to_return(ok)

        # JSON, like the MCP client sends -- form encoding would flatten 20 to "20".
        post api_v1_change_plans_path, params: {
          connection: connection.name, type: "target", operation: "update", target_kong_id: target_id, attributes: { weight: 20 }
        }, headers: auth(token), as: :json

        expect(response).to have_http_status(:created)
        expect(JSON.parse(response.body)["diff"]).to eq({ "weight" => { "from" => 100, "to" => 20 } })
      end

      it "returns 422 with Kong's field messages, and no plan, when the schema rejects the body" do
        stub_request(:post, "https://kong-admin.test/schemas/upstreams/validate").to_return(
          status: 400, body: { message: "schema violation", fields: { healthchecks: { active: { http_path: "should start with: /" } } } }.to_json
        )

        post api_v1_change_plans_path, params: {
          connection: connection.name, type: "upstream", operation: "create",
          attributes: { name: "orders", healthchecks: { active: { http_path: "health" } } }
        }, headers: auth(token)

        expect(response).to have_http_status(:unprocessable_entity)
        expect(JSON.parse(response.body)["error"]).to include("healthchecks.active.http_path: should start with: /")
        expect(ChangePlan.count).to eq(0)
      end

      it "returns 422, not a misleading 403, when a target create names no upstream" do
        post api_v1_change_plans_path, params: {
          connection: connection.name, type: "target", operation: "create", attributes: { target: "10.0.0.1:8080" }
        }, headers: auth(token)

        expect(response).to have_http_status(:unprocessable_entity)
        expect(JSON.parse(response.body)["error"]).to include("upstream")
        expect(ChangePlan.count).to eq(0)
      end

      it "still returns 403 when the credential can't write" do
        connection.update!(access_level: "ro")

        post api_v1_change_plans_path, params: {
          connection: connection.name, type: "upstream", operation: "create", attributes: { name: "orders" }
        }, headers: auth(token)

        expect(response).to have_http_status(:forbidden)
      end

      it "applies a target create through the nested upstream path" do
        plan = create(:change_plan, kong_connection: connection, actor_kind: "agent", entity_type: "target", operation: "create",
          target_kong_id: nil, parent_kong_id: upstream_id, before: {}, after: { "target" => "10.0.0.1:8080" }, base_updated_at: nil)
        post_target = stub_request(:post, "https://kong-admin.test/upstreams/#{upstream_id}/targets")
          .to_return(status: 201, body: { id: target_id, target: "10.0.0.1:8080", upstream: { id: upstream_id }, updated_at: 1_700_000_000 }.to_json)

        post apply_api_v1_change_plan_path(plan), params: { connection: connection.name }, headers: auth(token)

        expect(response).to have_http_status(:ok)
        expect(post_target).to have_been_requested
        expect(AuditEvent.last.entity_name).to eq("10.0.0.1:8080")
      end
    end
  end

  describe "POST /api/v1/change_plans/:id/apply (kong_apply)" do
    it "applies a pending plan and records an agent audit event" do
      kong_id = "22222222-2222-2222-2222-222222222222"
      connection = create(:kong_connection, admin_url: "https://kong-admin.test", access_level: "rw", credential_mode: "stored", auth_secret: "devpassword")
      token = token_for(connection)
      plan = create(:change_plan, kong_connection: connection, actor_kind: "agent", target_kong_id: kong_id,
        before: { "id" => kong_id, "name" => "svc", "tags" => [ "payment" ], "updated_at" => 1_700_000_000 },
        after: { "id" => kong_id, "name" => "svc", "tags" => %w[payment deprecated], "updated_at" => 1_700_000_000 },
        base_updated_at: Time.zone.at(1_700_000_000))
      stub_request(:get, "https://kong-admin.test/services/#{kong_id}")
        .to_return(status: 200, body: { id: kong_id, name: "svc", tags: [ "payment" ], updated_at: 1_700_000_000 }.to_json)
      stub_request(:patch, "https://kong-admin.test/services/#{kong_id}")
        .to_return(status: 200, body: { id: kong_id, name: "svc", tags: %w[payment deprecated], updated_at: 1_700_000_500 }.to_json)

      post apply_api_v1_change_plan_path(plan), params: { connection: connection.name }, headers: auth(token)

      expect(response).to have_http_status(:ok)
      json = JSON.parse(response.body)
      expect(json["status"]).to eq("applied")
      expect(AuditEvent.find(json["audit_event_id"]).actor_kind).to eq("agent")
    end

    it "returns 403 before touching Kong when the connection is rank>=2 on direct apply_mode" do
      connection = create(:kong_connection, name: "uat-direct", env: "uat", rank: 2, apply_mode: "direct",
        credential_mode: "stored", access_level: "rw", auth_secret: "devpassword")
      token = token_for(connection)
      plan = create(:change_plan, kong_connection: connection, actor_kind: "agent")

      post apply_api_v1_change_plan_path(plan), params: { connection: connection.name }, headers: auth(token)

      expect(response).to have_http_status(:forbidden)
      expect(response.body).to include("PR mode")
      expect(plan.reload.status).to eq("pending")
    end
  end

  describe "a non-String connection param" do
    let(:connection) { create(:kong_connection, name: "dev", admin_url: "https://kong-admin.test", access_level: "rw", credential_mode: "stored", auth_secret: "devpassword") }
    let(:token) { token_for(connection) }
    let(:variants) { { "hash" => { a: "dev" }, "array" => [ "dev" ], "array of a bound name and a blank" => [ "dev", "" ] } }

    it "is treated like an unbound connection name (401) on kong_plan, creating no plan" do
      variants.each do |label, value|
        post api_v1_change_plans_path, params: { connection: value, type: "service", operation: "create", attributes: { name: "x" } },
          headers: auth(token)

        expect(response).to have_http_status(:unauthorized), label
        expect(ChangePlan.count).to eq(0), label
      end
    end

    it "is treated like an unbound connection name (401) on kong_apply, leaving the plan pending" do
      plan = create(:change_plan, kong_connection: connection, actor_kind: "agent", entity_type: "service", operation: "create",
        target_kong_id: nil, before: {}, after: { "name" => "x" }, diff: { "operation" => "create" }, base_updated_at: nil)

      variants.each do |label, value|
        post apply_api_v1_change_plan_path(plan), params: { connection: value }, headers: auth(token)

        expect(response).to have_http_status(:unauthorized), label
        expect(plan.reload.status).to eq("pending"), label
      end
    end
  end

  describe "certificates and SNIs (M5b)" do
    let(:connection) { create(:kong_connection, admin_url: "https://kong-admin.test", access_level: "rw", credential_mode: "stored", auth_secret: "devpassword") }
    let(:token) { token_for(connection) }
    let(:cert_id) { "dddddddd-0000-0000-0000-00000000000d" }
    let(:fixture) { PemFixtures.self_signed(days: 60) }
    let(:ref) { "{vault://env/cert-pay-key}" }
    let(:ok) { { status: 200, body: { message: "schema validation successful" }.to_json } }

    def plan_cert(attributes)
      post api_v1_change_plans_path, params: { connection: connection.name, type: "certificate", operation: "create", attributes: attributes },
        headers: auth(token), as: :json
    end

    it "proposes a certificate whose key is a vault reference" do
      stub_request(:post, "https://kong-admin.test/schemas/certificates/validate").to_return(ok)

      plan_cert({ cert: fixture[:cert_pem], key: ref, snis: [ "pay.example.internal" ] })

      expect(response).to have_http_status(:created)
      expect(ChangePlan.find(JSON.parse(response.body)["id"]).after["key"]).to eq(ref)
    end

    it "returns 422 -- not 403 -- for a pasted private key, never echoing it, and creates no plan" do
      plan_cert({ cert: fixture[:cert_pem], key: fixture[:key_pem] })

      expect(response).to have_http_status(:unprocessable_entity)
      expect(JSON.parse(response.body)["error"]).to include("{vault://env/")
      expect(response.body).not_to include("PRIVATE KEY")
      expect(ChangePlan.count).to eq(0)
    end

    it "returns 422 for a decK placeholder on a direct-mode connection" do
      plan_cert({ cert: fixture[:cert_pem], key: '${{ env "DECK_CERT_A" }}' })

      expect(response).to have_http_status(:unprocessable_entity)
    end

    it "proposes an SNI under a certificate given as parent_kong_id" do
      stub_request(:post, "https://kong-admin.test/schemas/snis/validate").to_return(ok)

      post api_v1_change_plans_path, params: { connection: connection.name, type: "sni", operation: "create", parent_kong_id: cert_id,
        attributes: { name: "api.example.internal" } }, headers: auth(token), as: :json

      expect(response).to have_http_status(:created)
      expect(ChangePlan.last.after).to eq({ "name" => "api.example.internal", "certificate" => { "id" => cert_id } })
    end

    describe "kong_apply and the env-var acknowledgement" do
      let(:plan) do
        create(:change_plan, kong_connection: connection, actor_kind: "agent", entity_type: "certificate", operation: "create",
          target_kong_id: nil, before: {}, after: { "cert" => fixture[:cert_pem], "key" => ref, "snis" => [ "pay.example.internal" ] },
          diff: { "operation" => "create" }, base_updated_at: nil)
      end

      def stub_create
        stub_request(:post, "https://kong-admin.test/certificates").to_return(status: 201, body: {
          id: cert_id, cert: fixture[:cert_pem], key: ref, snis: [ "pay.example.internal" ], updated_at: 1_700_000_000
        }.to_json)
      end

      it "refuses without acknowledge_env_vars, naming the variable, and leaves the plan pending" do
        post apply_api_v1_change_plan_path(plan), params: { connection: connection.name }, headers: auth(token)

        expect(response).to have_http_status(:forbidden)
        expect(JSON.parse(response.body)["error"]).to include("CERT_PAY_KEY")
        expect(plan.reload.status).to eq("pending")
      end

      it "applies with acknowledge_env_vars: true and records the agent's confirmation" do
        stub_create

        post apply_api_v1_change_plan_path(plan), params: { connection: connection.name, acknowledge_env_vars: true },
          headers: auth(token), as: :json

        expect(response).to have_http_status(:ok)
        event = AuditEvent.find(JSON.parse(response.body)["audit_event_id"])
        expect(event.actor_kind).to eq("agent")
        expect(event.context).to eq({ "acknowledged_env_vars" => [ "CERT_PAY_KEY" ] })
      end

      it "accepts the form-encoded strings \"true\" and \"1\"" do
        stub_create

        post apply_api_v1_change_plan_path(plan), params: { connection: connection.name, acknowledge_env_vars: "1" }, headers: auth(token)

        expect(response).to have_http_status(:ok)
        expect(plan.reload.status).to eq("applied")
      end

      it "does not treat the string \"false\" as an acknowledgement" do
        post apply_api_v1_change_plan_path(plan), params: { connection: connection.name, acknowledge_env_vars: "false" }, headers: auth(token)

        expect(response).to have_http_status(:forbidden)
      end

      [ false, "0", "yes", "TRUE", [ true ], [ "true" ], { "a" => true }, 1, nil ].each do |value|
        it "refuses acknowledge_env_vars: #{value.inspect} and leaves the plan pending" do
          post apply_api_v1_change_plan_path(plan), params: { connection: connection.name, acknowledge_env_vars: value },
            headers: auth(token), as: :json

          expect(response).to have_http_status(:forbidden)
          expect(JSON.parse(response.body)["error"]).to include("CERT_PAY_KEY")
          expect(plan.reload.status).to eq("pending")
        end
      end
    end
  end
end
