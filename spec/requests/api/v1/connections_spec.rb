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
    expect(json["data"].map { |c| c["name"] }).to eq([ "bound/dev" ])
    expect(json["data"].first).to include("env" => "dev", "rank" => 0, "apply_mode" => "direct")
  end

  describe "project/env names (R1.6)" do
    it "lists connections by project/env with project and env apart" do
      env = create(:project_env, name: "uat", apply_mode: "pr", source: "registry", project: create(:project, key: "project-a"))
      connection = create(:kong_connection, :stored, project_env: env)
      _pat, raw = PersonalAccessToken.issue!(operator: "o", issued_by_username: "u", connection_ids: [ connection.id ])

      get api_v1_connections_path, headers: auth(raw)

      expect(response.parsed_body["data"]).to eq([ {
        "name" => "project-a/uat", "project" => "project-a", "env" => "uat", "rank" => 2, "apply_mode" => "pr",
        "access_level" => nil, "credential_mode" => "stored", "kong_version" => nil } ])
    end

    it "reports an env with no apply_mode as null" do
      connection = create(:kong_connection, :stored, project_env: create(:project_env, apply_mode: nil))
      _pat, raw = PersonalAccessToken.issue!(operator: "o", issued_by_username: "u", connection_ids: [ connection.id ])

      get api_v1_connections_path, headers: auth(raw)

      expect(response.parsed_body["data"].first).to include("apply_mode" => nil)
    end

    it "does not resolve a bare env name, which would be ambiguous across projects" do
      env = create(:project_env, name: "uat", apply_mode: "pr", source: "registry", project: create(:project, key: "project-a"))
      connection = create(:kong_connection, :stored, project_env: env)
      _pat, raw = PersonalAccessToken.issue!(operator: "o", issued_by_username: "u", connection_ids: [ connection.id ])

      get api_v1_entities_path, params: { connection: "uat", type: "service" }, headers: auth(raw)

      expect(response).to have_http_status(:unauthorized)
      expect(response.parsed_body["error"]).to include("project/env")
    end

    it "keeps a token issued before the migration working under the new name" do
      connection = create(:kong_connection, :stored, project_env: create(:project_env, name: "dev-readwrite",
        rank: 0, project: create(:project, key: "default")))
      _pat, raw = PersonalAccessToken.issue!(operator: "o", issued_by_username: "u", connection_ids: [ connection.id ])

      get api_v1_entities_path, params: { connection: "default/dev-readwrite", type: "service" }, headers: auth(raw)

      expect(response).to have_http_status(:ok)
    end
  end
end
