require "rails_helper"

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

      post api_v1_change_plans_path, params: { connection: connection.name, type: "upstream", operation: "update" }, headers: auth(token)

      expect(response).to have_http_status(:bad_request)
      expect(ChangePlan.count).to eq(0)
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
end
