require "rails_helper"

RSpec.describe Kong::ForwardedRequest do
  let(:connection) { create(:kong_connection) }

  def service(path: "/api", host: "billing.internal", port: 8080, protocol: "http", **extra)
    create(:kong_entity, kong_connection: connection, entity_type: "service", name: "billing",
      data: { "protocol" => protocol, "host" => host, "port" => port, "path" => path, "connect_timeout" => 60_000,
              "read_timeout" => 60_000, "write_timeout" => 60_000, "retries" => 5, "tls_verify" => nil }.merge(extra.stringify_keys))
  end

  def route(svc, paths:, strip_path: true, path_handling: "v0", preserve_host: false, host: "api.example.com")
    create(:kong_entity, kong_connection: connection, entity_type: "route", name: "r", parent_type: "service",
      parent_kong_id: svc&.kong_id,
      data: { "protocols" => %w[http https], "hosts" => [ host ], "paths" => paths, "methods" => [], "regex_priority" => 0,
              "strip_path" => strip_path, "path_handling" => path_handling, "preserve_host" => preserve_host })
  end

  def forward(path, host: "api.example.com", query: nil, steps: [])
    match = Kong::RouteMatcher.call(connection: connection, host: host, path: path, method: "GET")
    described_class.call(connection: connection, match: match, host: host, path: path, query: query, steps: steps)
  end

  it "strips the route's path, adds the service's, and passes the query on" do
    route(service, paths: %w[/billing/v1])

    result = forward("/billing/v1/invoices/42", query: "status=paid")

    expect(result.route_effect).to have_attributes(removed: "/billing/v1", kept: "/invoices/42", query: "status=paid",
      host_header: "billing.internal:8080", strip_path: true, preserve_host: false)
    expect(result.service_effect).to have_attributes(url: "http://billing.internal:8080/api/invoices/42?status=paid",
      added_path: "/api", port: 8080, retries: 5)
    expect(result.service_effect.timeouts).to eq(connect: 60_000, read: 60_000, write: 60_000)
  end

  it "leaves out the default port" do
    route(service(port: 443, protocol: "https"), paths: %w[/b])
    expect(forward("/b/x").service_effect.url).to eq("https://billing.internal/api/x")
    expect(forward("/b/x").route_effect.host_header).to eq("billing.internal")
  end

  it "sends the client's host when preserve_host is on" do
    route(service, paths: %w[/b], preserve_host: true)
    expect(forward("/b/x").route_effect.host_header).to eq("api.example.com")
  end

  it "goes to an upstream's weighted targets, and says 503 when there are none" do
    svc = service(host: "billing-upstream", port: 80)
    route(svc, paths: %w[/b])
    upstream = create(:kong_entity, kong_connection: connection, entity_type: "upstream", name: "billing-upstream",
      data: { "name" => "billing-upstream", "algorithm" => "round-robin" })
    %w[10.0.4.11:8080 10.0.4.12:8080].each do |target|
      create(:kong_entity, kong_connection: connection, entity_type: "target", name: target, parent_type: "upstream",
        parent_kong_id: upstream.kong_id, data: { "target" => target, "weight" => 100 })
    end
    create(:kong_entity, kong_connection: connection, entity_type: "target", name: "10.0.4.13:8080", parent_type: "upstream",
      parent_kong_id: upstream.kong_id, data: { "target" => "10.0.4.13:8080", "weight" => 0 })

    effect = forward("/b/x").service_effect

    expect(effect.upstream).to have_attributes(name: "billing-upstream", algorithm: "round-robin",
      targets: %w[10.0.4.11:8080 10.0.4.12:8080])
    expect(effect.not_forwarded).to be_nil

    KongEntity.where(entity_type: "target").find_each { _1.update!(data: _1.data.merge("weight" => 0)) }
    expect(forward("/b/x").service_effect.not_forwarded).to eq(503)
  end

  it "says Kong answers itself when request-termination is enabled" do
    route(service, paths: %w[/b])
    plugin = create(:kong_entity, kong_connection: connection, entity_type: "plugin", name: "request-termination",
      data: { "name" => "request-termination", "config" => { "status_code" => 503, "message" => "Billing is under maintenance" } })
    step = Kong::PluginChain::Step.new(plugin: plugin, scope: "route", priority: 2, enabled: true, overrides: [],
      effect: Kong::PluginEffects.for("request-termination", config: plugin.data["config"]))

    expect(forward("/b/x", steps: [ step ]).answered_by).to eq(plugin: plugin, status: 503, message: "Billing is under maintenance")
  end

  it "has no service effect for a route without a service" do
    route(nil, paths: %w[/b])
    result = forward("/b/x")
    expect(result.service_effect).to be_nil
    expect(result.route_effect.kept).to eq("/x")
  end

  describe "against compose Kong (spec/fixtures/kong_router/join.json, R5.0)" do
    fixture = JSON.parse(Rails.root.join("spec/fixtures/kong_router/join.json").read)

    fixture.fetch("cases").each do |kase|
      it "forwards what Kong #{fixture['kong_version']} forwarded: #{kase['name']}" do
        host = kase.dig("request", "host")
        path, query = kase.dig("request", "path").split("?", 2)
        svc = service(host: "127.0.0.1", port: 8000, path: kase["service_path"])
        route(svc, paths: [ kase["route_path"] ], strip_path: kase["strip_path"], path_handling: kase["path_handling"],
          preserve_host: kase["preserve_host"], host: host)

        result = forward(path, host: host, query: query)
        url = URI(result.service_effect.url)

        expect(url.path).to eq(kase.dig("got", "path"))
        expect(url.query).to eq(query)
        expect(result.route_effect.host_header).to eq(kase.dig("got", "host"))
      end
    end
  end
end
