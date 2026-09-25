require "rails_helper"

RSpec.describe "Hint preference", type: :request do
  it "remembers compact hints across requests (a permanent cookie, read on the server)" do
    patch hint_preference_path, params: { mode: "compact" }, headers: { "HTTP_REFERER" => connections_url }
    expect(response).to redirect_to(connections_url)
    expect(cookies[:kongsole_hints]).to eq("compact")

    get connections_path
    expect(controller.send(:detailed_hints?)).to be(false)
  end

  # Owner decision 2026-09-26: too much text on every page -- a browser that
  # never chose gets compact hints; only an explicit "detailed" gets detail.
  it "gives compact hints to a browser that never chose" do
    get connections_path
    expect(controller.send(:detailed_hints?)).to be(false)
  end

  it "shows detailed hints only to a browser that chose them" do
    patch hint_preference_path, params: { mode: "detailed" }, headers: { "HTTP_REFERER" => connections_url }
    get connections_path
    expect(controller.send(:detailed_hints?)).to be(true)
  end

  it "treats anything but 'detailed' as compact" do
    cookies[:kongsole_hints] = "<script>"
    get connections_path
    expect(controller.send(:detailed_hints?)).to be(false)
  end

  it "rejects an unknown mode without touching the cookie" do
    patch hint_preference_path, params: { mode: "bogus" }
    expect(response).to have_http_status(:unprocessable_entity)
    expect(cookies[:kongsole_hints]).to be_nil
  end
end
