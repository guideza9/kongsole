require "rails_helper"

RSpec.describe "Health", type: :request do
  it "renders the connection health table" do
    create(:kong_connection, name: "dev", last_status: "ok")
    get health_path
    expect(response).to have_http_status(:ok)
    expect(response.body).to include("dev")
  end

  it "presents the stored status as the last login attempt's, not a live check" do
    create(:kong_connection, name: "dev", last_status: "unavailable")
    get health_path
    expect(response.body).to include("Last known status").and include("Nothing here is checked live")
  end

  it "still answers the Rails process liveness check at /up" do
    get "/up"
    expect(response).to have_http_status(:ok)
  end
end
