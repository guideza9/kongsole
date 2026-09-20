require "rails_helper"

RSpec.describe "API::V1::Connections", type: :request do
  def auth(raw_token)
    { "Authorization" => "Bearer #{raw_token}" }
  end

  it "returns 401 with no token" do
    get api_v1_connections_path
    expect(response).to have_http_status(:unauthorized)
  end

  it "returns only the connections this token is bound to" do
    bound = create(:kong_connection, name: "bound", credential_mode: "stored", env: "dev", rank: 0)
    create(:kong_connection, name: "not-bound", credential_mode: "stored")
    _pat, raw = PersonalAccessToken.issue!(operator: "alice", issued_by_username: "alice", connection_ids: [ bound.id ])

    get api_v1_connections_path, headers: auth(raw)

    expect(response).to have_http_status(:ok)
    json = JSON.parse(response.body)
    expect(json["data"].map { |c| c["name"] }).to eq([ "bound" ])
    expect(json["data"].first).to include("env" => "dev", "rank" => 0, "apply_mode" => "direct")
  end
end
