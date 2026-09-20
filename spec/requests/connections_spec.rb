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
        name: "sit", env: "sit", rank: 1, admin_url: "https://kong-sit-admin.internal",
        apply_mode: "direct", credential_mode: "session", auth_type: "basic"
      }
    }
    expect(response).to redirect_to(connections_path)
    expect(KongConnection.find_by(name: "sit")).to be_present
  end

  it "rejects a non-https, non-localhost admin_url" do
    post connections_path, params: {
      kong_connection: {
        name: "bad", env: "dev", rank: 0, admin_url: "http://kong-dev-admin.internal",
        apply_mode: "direct", credential_mode: "session", auth_type: "basic"
      }
    }
    expect(response).to have_http_status(:unprocessable_entity)
    expect(KongConnection.find_by(name: "bad")).to be_nil
  end

  it "never lets allow_insecure_http be set through the web form (config-file-only escape hatch)" do
    post connections_path, params: {
      kong_connection: {
        name: "sneaky", env: "dev", rank: 0, admin_url: "http://kong-dev-admin.internal",
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
