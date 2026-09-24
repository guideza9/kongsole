require "rails_helper"

RSpec.describe Kong::ErrorExplanation do
  {
    Kong::Client::Unauthorized => "unauthorized",
    Kong::Client::Forbidden => "forbidden",
    Kong::Client::RouteNotMatched => "route_not_matched",
    Kong::Client::EntityNotFound => "entity_not_found",
    Kong::Client::RateLimited => "rate_limited",
    Kong::Client::UpstreamUnavailable => "upstream_unavailable",
    Kong::Client::UnexpectedResponse => "unexpected_response"
  }.each do |klass, key|
    it "explains #{klass.name.demodulize} with its own cause and next step" do
      result = described_class.for(klass.new("x"))
      expect(result.key).to eq(key)
      expect([ result.title, result.cause, result.next_step ]).to all(be_present)
    end
  end

  { dns: "network_dns_failed", refused: "network_refused", timeout: "network_timed_out", tls: "network_tls_failed", other: "connection_failed" }.each do |kind, key|
    it "explains an unreachable #{kind} as #{key}, not as the Admin API being down" do
      result = described_class.for(Kong::Client::NetworkUnreachable.new("x", kind: kind))
      expect(result.key).to eq(key)
      expect(result.cause).not_to match(/admin api .*(down|not listening)/i)
    end
  end

  it "adds the project's network note to the next step of a network problem" do
    result = described_class.for(Kong::Client::NetworkUnreachable.new("x", kind: :timeout),
      network_note: "Reachable from the NONPROD VPN only")
    expect(result.next_step).to include("Reachable from the NONPROD VPN only")
  end

  it "classifies a bare Faraday error the same way instead of raising" do
    expect(described_class.for(Faraday::ConnectionFailed.new(SocketError.new("getaddrinfo failed"))).key).to eq("network_dns_failed")
  end

  it "never tells a read-only credential that the entity is missing" do
    ro = described_class.for(Kong::Client::RouteNotMatched.new("x"))
    expect(ro.cause).not_to match(/not found|does not exist/i)
  end
end
