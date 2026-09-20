require "rails_helper"

RSpec.describe "API::V1::Entities", type: :request do
  let(:connection) { create(:kong_connection, credential_mode: "stored") }
  let(:other_connection) { create(:kong_connection, name: "other", credential_mode: "stored") }

  def token_for(*connections)
    _pat, raw = PersonalAccessToken.issue!(operator: "alice", issued_by_username: "alice", connection_ids: connections.map(&:id))
    raw
  end

  def auth(raw_token)
    { "Authorization" => "Bearer #{raw_token}" }
  end

  it "returns 401 with no Authorization header" do
    get api_v1_entities_path, params: { connection: connection.name, type: "service" }
    expect(response).to have_http_status(:unauthorized)
  end

  it "returns 401 for a garbage token" do
    get api_v1_entities_path, params: { connection: connection.name, type: "service" }, headers: auth("garbage")
    expect(response).to have_http_status(:unauthorized)
  end

  it "returns 401 when the connection isn't in this token's set" do
    token = token_for(connection)
    get api_v1_entities_path, params: { connection: other_connection.name, type: "service" }, headers: auth(token)
    expect(response).to have_http_status(:unauthorized)
  end

  it "returns 400 when type is missing" do
    token = token_for(connection)
    get api_v1_entities_path, params: { connection: connection.name }, headers: auth(token)
    expect(response).to have_http_status(:bad_request)
  end

  it "returns the §9 JSON shape: data + meta" do
    token = token_for(connection)
    create(:kong_entity, kong_connection: connection, name: "payments-api", tags: [ "payment" ])

    get api_v1_entities_path, params: { connection: connection.name, type: "service" }, headers: auth(token)

    expect(response).to have_http_status(:ok)
    json = JSON.parse(response.body)
    expect(json["data"].first["name"]).to eq("payments-api")
    expect(json["meta"]).to include("connection" => connection.name, "has_more" => false)
  end

  it "only returns the fields asked for via fields=" do
    token = token_for(connection)
    create(:kong_entity, kong_connection: connection, name: "payments-api", tags: [ "payment" ])

    get api_v1_entities_path, params: { connection: connection.name, type: "service", fields: "id,name" }, headers: auth(token)

    json = JSON.parse(response.body)
    expect(json["data"].first.keys).to contain_exactly("id", "name")
  end

  it "returns 400 for a tampered cursor" do
    token = token_for(connection)
    get api_v1_entities_path, params: { connection: connection.name, type: "service", cursor: "garbage" }, headers: auth(token)
    expect(response).to have_http_status(:bad_request)
  end

  it "returns 401 once the token is revoked" do
    _pat, raw = PersonalAccessToken.issue!(operator: "alice", issued_by_username: "alice", connection_ids: [ connection.id ])
    PersonalAccessToken.active.first.revoke!

    get api_v1_entities_path, params: { connection: connection.name, type: "service" }, headers: auth(raw)
    expect(response).to have_http_status(:unauthorized)
  end
end
