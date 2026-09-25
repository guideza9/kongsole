require "rails_helper"

RSpec.describe "Connections", type: :request do
  it "lists connections on the root path" do
    create(:kong_connection, name: "dev")
    get root_path
    expect(response).to have_http_status(:ok)
    expect(response.body).to include("dev")
  end

  it "creates a connection" do
    post connections_path, params: {
      kong_connection: {
        name: "sit", env: "sit", admin_url: "https://kong-sit-admin.internal",
        apply_mode: "direct", credential_mode: "session", auth_type: "basic"
      }
    }
    expect(response).to redirect_to(connections_path)
    expect(KongConnection.find_by(name: "default/sit")).to be_present
  end

  it "shows policy in words on the connection card, not as raw tokens" do
    create(:kong_connection, name: "uat-pr", env: "uat", apply_mode: "pr", access_level: "ro", credential_kind: "shared")

    get connections_path

    expect(response.body).to include("PR mode").and include("Read-only").and include("Shared credential")
    expect(response.body).not_to include("apply: pr")
    expect(response.body).not_to match(/rank \d/)
  end

  it "sets Remove apart from Log in and Edit on its own side of a divider" do
    create(:kong_connection, name: "dev")

    get connections_path

    row = Nokogiri::HTML(response.body).at_css(".row-card")
    remove = row.at_xpath(".//button[normalize-space()='Remove']")
    expect(remove.ancestors("div").first["class"]).to include("border-l")
    expect(row.css("a").map { |a| a.text.strip }).to eq([ "Log in", "Edit" ])
  end

  it "has no rank input and ignores a submitted rank" do
    get new_connection_path
    expect(response.body).not_to include("kong_connection[rank]")

    post connections_path, params: {
      kong_connection: {
        name: "prod-sneaky", env: "prod", rank: 0, admin_url: "https://kong-prod-admin-ro.internal",
        apply_mode: "pr", credential_mode: "session", auth_type: "basic"
      }
    }
    expect(KongConnection.find_by(name: "default/prod-sneaky").rank).to eq(3)
  end

  it "rejects a non-https, non-localhost admin_url" do
    post connections_path, params: {
      kong_connection: {
        name: "bad", env: "dev", admin_url: "http://kong-dev-admin.internal",
        apply_mode: "direct", credential_mode: "session", auth_type: "basic"
      }
    }
    expect(response).to have_http_status(:unprocessable_entity)
    expect(KongConnection.find_by(name: "bad")).to be_nil
  end

  it "never lets allow_insecure_http be set through the web form (config-file-only escape hatch)" do
    post connections_path, params: {
      kong_connection: {
        name: "sneaky", env: "dev", admin_url: "http://kong-dev-admin.internal",
        apply_mode: "direct", credential_mode: "session", auth_type: "basic",
        allow_insecure_http: true
      }
    }
    expect(response).to have_http_status(:unprocessable_entity)
    expect(KongConnection.find_by(name: "sneaky")).to be_nil
  end

  it "removes a connection from the registry" do
    connection = create(:kong_connection, name: "old")
    delete connection_path(connection)
    expect(response).to redirect_to(connections_path)
    expect(KongConnection.find_by(name: "old")).to be_nil
  end
end

RSpec.describe "GET /connections", type: :request do
  it "fills only one action (Add connection); per-row Log in is secondary" do
    create_list(:kong_connection, 2)
    get connections_path
    doc = Nokogiri::HTML(response.body)
    expect(doc.css(".btn-primary").map { |n| n.text.strip }).to eq([ "Add connection" ])
    expect(doc.css("a.btn-secondary").map { |n| n.text.strip }.count("Log in")).to eq(2)
  end
end
