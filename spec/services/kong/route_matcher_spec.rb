require "rails_helper"

RSpec.describe Kong::RouteMatcher do
  let(:connection) { create(:kong_connection) }
  let(:service) do
    create(:kong_entity, kong_connection: connection, entity_type: "service", name: "billing",
      data: { "name" => "billing", "host" => "billing.internal", "port" => 8080, "protocol" => "http" })
  end

  def route(name, created: Time.utc(2026, 1, 1), **data)
    create(:kong_entity, kong_connection: connection, entity_type: "route", name: name, kong_created_at: created,
      parent_type: "service", parent_kong_id: service.kong_id,
      data: { "name" => name, "protocols" => %w[http https], "hosts" => [], "paths" => [], "methods" => [],
              "regex_priority" => 0, "strip_path" => true, "path_handling" => "v0" }.merge(data.stringify_keys))
  end

  def trace(path, host: "api.example.com", method: "GET")
    described_class.call(connection: connection, host: host, path: path, method: method)
  end

  it "picks the longest matching prefix and says why the other lost" do
    route("api", paths: %w[/api])
    route("api-v1", paths: %w[/api/v1])

    result = trace("/api/v1/invoices")

    expect(result.route.name).to eq("api-v1")
    expect(result.service.name).to eq("billing")
    expect(result.matched_on).to include(path: "/api/v1", regex: false, matched: "/api/v1")
    expect(result.losers.map { [ _1[:route].name, _1[:reason] ] }).to eq([ [ "api", "a shorter prefix than /api/v1" ] ])
  end

  it "prefers a route that sets more conditions" do
    route("any-host", paths: %w[/api])
    route("this-host", paths: %w[/api], hosts: %w[api.example.com])
    expect(trace("/api").route.name).to eq("this-host")
  end

  it "matches a host typed in capitals or with a port (Review Focus 2)" do
    route("this-host", paths: %w[/api], hosts: %w[api.example.com])
    expect(trace("/api", host: "API.Example.com:8443").route&.name).to eq("this-host")
  end

  it "orders a route by its best path, not its first (Review Focus 3)" do
    route("many-paths", paths: %w[/a /api/v1])
    route("mid", paths: %w[/api])

    result = trace("/api/v1/x")

    expect(result.route.name).to eq("many-paths")
    expect(result.matched_on[:matched]).to eq("/api/v1")
  end

  it "records what a regex matched, for strip_path" do
    route("reports", paths: [ "~/reports/\\d{4}" ])
    expect(trace("/reports/2026/q3").matched_on).to include(regex: true, matched: "/reports/2026")
  end

  it "skips a regex Ruby cannot compile and says so, instead of failing" do
    route("pcre-only", paths: [ "~/api/(?<x>\\d+)(?(x)a|b)" ])
    result = trace("/api/1")
    expect(result.route).to be_nil
    expect(result.skipped.map { [ _1[:route].name, _1[:reason] ] }).to eq([ [ "pcre-only", "uses regex syntax Kongsole can't read" ] ])
  end

  it "skips an expressions route" do
    route("expr", expression: 'http.path ^= "/api"')
    expect(trace("/api").skipped.map { _1[:route].name }).to eq(%w[expr])
  end

  it "does not let a route that needs headers or SNI catch a traced request, and says why (final review)" do
    route("billing", paths: %w[/billing])
    route("billing-canary", paths: %w[/billing], headers: { "x-canary" => [ "1" ] })
    route("billing-tls", paths: %w[/billing], snis: %w[api.example.com])

    result = trace("/billing/x")

    expect(result.route.name).to eq("billing")
    expect(result.skipped.map { [ _1[:route].name, _1[:reason] ] }).to contain_exactly(
      [ "billing-canary", "matches on headers the tracer does not send" ],
      [ "billing-tls", "matches on SNI the tracer does not send" ])
  end

  it "ignores routes that take no http traffic" do
    route("tcp-only", protocols: %w[tcp], paths: [])
    expect(trace("/api").route).to be_nil
  end

  it "answers no route for a method the route does not allow" do
    route("reads", paths: %w[/api], methods: %w[GET])
    expect(trace("/api", method: "POST").route).to be_nil
  end

  it "reads only the read-model" do
    route("api", paths: %w[/api])
    trace("/api")
    expect(a_request(:any, //)).not_to have_been_made
  end

  describe "against compose Kong (spec/fixtures/kong_router/ordering.json, R5.0)" do
    fixture = JSON.parse(Rails.root.join("spec/fixtures/kong_router/ordering.json").read)

    fixture.fetch("cases").each do |kase|
      it "picks what Kong #{fixture['kong_version']} picked: #{kase['name']}" do
        host = kase.dig("request", "host")
        kase.fetch("routes").each_with_index do |attrs, index|
          route(attrs.fetch("name"), created: Time.utc(2026, 1, 1) + index,
            hosts: attrs.fetch("hosts", [ host ]), paths: attrs.fetch("paths", []), methods: attrs.fetch("methods", []),
            regex_priority: attrs.fetch("regex_priority", 0), headers: attrs.fetch("headers", {}))
        end

        result = trace(kase.dig("request", "path"), host: host, method: kase.dig("request", "method"))

        expect(result.route&.name).to eq(kase.dig("got", "route"))
      end
    end
  end
end
