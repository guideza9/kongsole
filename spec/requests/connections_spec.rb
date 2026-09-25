require "rails_helper"

RSpec.describe "Connections", type: :request do
  it "lists connections on the root path" do
    create(:kong_connection, name: "dev")
    get root_path
    expect(response).to have_http_status(:ok)
    expect(response.body).to include("dev")
  end

  let(:local_env) { create(:project_env, name: "sit", apply_mode: "direct", project: create(:project, key: "project-x")) }

  it "creates a connection for a local env, named project/env" do
    post connections_path, params: {
      kong_connection: {
        project_env_id: local_env.id, admin_url: "https://kong-sit-admin.internal",
        credential_mode: "session", auth_type: "basic"
      }
    }
    expect(response).to redirect_to(project_path(local_env.project))
    expect(KongConnection.find_by(name: "project-x/sit")).to be_present
  end

  it "never accepts apply_mode, rank or env from the connection form" do
    env = create(:project_env, apply_mode: "direct", rank: 0, source: "local")
    post connections_path, params: { kong_connection: { project_env_id: env.id, admin_url: "http://localhost:8001",
      credential_mode: "session", apply_mode: "pr", rank: 3, env: "prod" } }
    expect(KongConnection.last).to have_attributes(apply_mode: "direct", rank: 0)
  end

  it "refuses to edit a registry connection" do
    env = create(:project_env, source: "registry")
    connection = create(:kong_connection, project_env: env)
    patch connection_path(connection), params: { kong_connection: { admin_url: "http://localhost:9999" } }
    expect(response).to have_http_status(:forbidden)
    expect(connection.reload.admin_url).not_to eq("http://localhost:9999")
  end

  it "refuses to remove a registry connection" do
    connection = create(:kong_connection, project_env: create(:project_env, source: "registry"))
    delete connection_path(connection)
    expect(response).to have_http_status(:forbidden)
    expect(KongConnection.exists?(connection.id)).to be(true)
  end

  it "refuses to attach a UI connection to an env from connections.yml" do
    env = create(:project_env, source: "registry")
    post connections_path, params: { kong_connection: { project_env_id: env.id, admin_url: "http://localhost:8001", credential_mode: "session" } }
    expect(response).to have_http_status(:forbidden)
    expect(KongConnection.count).to eq(0)
  end

  it "shows policy in words on the connection card, not as raw tokens" do
    connection = create(:kong_connection, name: "uat-pr", env: "uat", apply_mode: "pr", access_level: "ro", credential_kind: "shared")

    get project_path(connection.project)

    expect(response.body).to include("PR mode").and include("Read-only").and include("Shared credential")
    expect(response.body).not_to include("apply: pr")
    expect(response.body).not_to match(/rank \d/)
  end

  it "sets Remove apart from Log in and Edit on its own side of a divider" do
    connection = create(:kong_connection, name: "dev")

    get project_path(connection.project)

    row = Nokogiri::HTML(response.body).at_css(".row-card")
    remove = row.at_xpath(".//button[normalize-space()='Remove connection']")
    expect(remove.ancestors("div").first["class"]).to include("border-l")
    expect(row.css("a").map { |a| a.text.strip }).to eq([ "Log in", "Edit environment", "Edit connection" ])
  end

  it "has no rank input and ignores a submitted rank" do
    get new_connection_path
    expect(response.body).not_to include("kong_connection[rank]")

    env = create(:project_env, name: "prod", apply_mode: "direct", project: create(:project, key: "project-x"))
    post connections_path, params: {
      kong_connection: {
        project_env_id: env.id, rank: 0, admin_url: "https://kong-prod-admin-ro.internal",
        credential_mode: "session", auth_type: "basic"
      }
    }
    expect(KongConnection.find_by(name: "project-x/prod").rank).to eq(3)
  end

  it "rejects a non-https, non-localhost admin_url" do
    post connections_path, params: {
      kong_connection: {
        project_env_id: local_env.id, admin_url: "http://kong-dev-admin.internal",
        credential_mode: "session", auth_type: "basic"
      }
    }
    expect(response).to have_http_status(:unprocessable_entity)
    expect(KongConnection.count).to eq(0)
  end

  it "never lets allow_insecure_http be set through the web form (config-file-only escape hatch)" do
    post connections_path, params: {
      kong_connection: {
        project_env_id: local_env.id, admin_url: "http://kong-dev-admin.internal",
        credential_mode: "session", auth_type: "basic",
        allow_insecure_http: true
      }
    }
    expect(response).to have_http_status(:unprocessable_entity)
    expect(KongConnection.count).to eq(0)
  end

  it "removes a local connection from this machine and goes back to its project" do
    connection = create(:kong_connection, name: "old")
    delete connection_path(connection)
    expect(response).to redirect_to(project_path(connection.project))
    expect(flash[:notice]).to eq("Connection \"#{connection.name}\" removed from this machine.")
    expect(KongConnection.exists?(connection.id)).to be(false)
  end

  # R1.18: the filter works without JavaScript, as a plain GET.
  it "filters projects with ?q=" do
    create(:project, key: "payments", name: "Payments")
    create(:project, key: "card", name: "Card Switch")
    get connections_path(q: "pay")
    expect(response.body).to include("Payments")
    expect(response.body).not_to include("Card Switch")
  end
end

RSpec.describe "GET /connections", type: :request do
  it "fills only one action (New project, R1.8); each env's chip is its Log in (R1.19)" do
    create_list(:kong_connection, 2)
    get connections_path
    doc = Nokogiri::HTML(response.body)
    expect(doc.css(".btn-primary").map { |n| n.text.strip }).to eq([ "New project" ])
    expect(doc.css("a.launcher__env").map { |a| a["aria-label"] }).to all(start_with("Log in to "))
    expect(doc.css("a.launcher__env").size).to eq(2)
  end
end
