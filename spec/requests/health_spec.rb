require "rails_helper"

RSpec.describe "Health", type: :request do
  it "renders the connection health table" do
    create(:kong_connection, name: "dev", last_status: "ok")
    get health_path
    expect(response).to have_http_status(:ok)
    expect(response.body).to include("dev")
  end

  it "still answers the Rails process liveness check at /up" do
    get "/up"
    expect(response).to have_http_status(:ok)
  end
end
