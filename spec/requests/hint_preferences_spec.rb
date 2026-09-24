require "rails_helper"

RSpec.describe "Hint preference", type: :request do
  it "remembers compact hints across requests (a permanent cookie, read on the server)" do
    patch hint_preference_path, params: { mode: "compact" }, headers: { "HTTP_REFERER" => connections_url }
    expect(response).to redirect_to(connections_url)
    expect(cookies[:kongsole_hints]).to eq("compact")

    get connections_path
    expect(controller.send(:detailed_hints?)).to be(false)
  end

  it "treats anything but 'compact' as detailed" do
    cookies[:kongsole_hints] = "<script>"
    get connections_path
    expect(controller.send(:detailed_hints?)).to be(true)
  end

  it "rejects an unknown mode without touching the cookie" do
    patch hint_preference_path, params: { mode: "bogus" }
    expect(response).to have_http_status(:unprocessable_entity)
    expect(cookies[:kongsole_hints]).to be_nil
  end
end
