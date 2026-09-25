require "rails_helper"

RSpec.describe Kong::RouteOverlap do
  let(:connection) { create(:kong_connection) }
  let(:service) { create(:kong_entity, kong_connection: connection, entity_type: "service", name: "billing") }

  def route(name, hosts: [], paths: [], methods: [])
    create(:kong_entity, kong_connection: connection, entity_type: "route", name: name,
      parent_type: "service", parent_kong_id: service.kong_id,
      data: { "name" => name, "hosts" => hosts, "paths" => paths, "methods" => methods })
  end

  def check(**kw) = described_class.check(connection: connection, hosts: [], paths: [], methods: [], **kw)

  it "flags an identical path on the same host" do
    route("old", hosts: %w[api.example.com], paths: %w[/billing])
    expect(check(hosts: %w[api.example.com], paths: %w[/billing])).to contain_exactly(include(route_name: "old", reason: :exact))
  end

  it "flags a prefix in either direction" do
    route("v1", hosts: %w[api.example.com], paths: %w[/api/v1])
    expect(check(hosts: %w[api.example.com], paths: %w[/api]).first[:reason]).to eq(:prefix)
  end

  it "flags a prefix the other way round too" do
    route("api", hosts: %w[api.example.com], paths: %w[/api])
    expect(check(hosts: %w[api.example.com], paths: %w[/api/v1]).first[:reason]).to eq(:prefix)
  end

  it "treats a route with no hosts as matching every host" do
    route("catch-all", paths: %w[/billing])
    expect(check(hosts: %w[api.example.com], paths: %w[/billing])).not_to be_empty
  end

  it "matches wildcards the way Kong does" do
    route("wild", hosts: %w[*.example.com], paths: %w[/x])
    expect(check(hosts: %w[api.example.com], paths: %w[/x])).not_to be_empty
    expect(check(hosts: %w[example.com], paths: %w[/x])).to be_empty
  end

  it "does not flag routes whose methods do not intersect" do
    route("reads", paths: %w[/billing], methods: %w[GET])
    expect(check(paths: %w[/billing], methods: %w[POST])).to be_empty
  end

  it "says it cannot tell for regex paths instead of guessing" do
    route("rx", paths: [ "~/billing/v[0-9]+$" ])
    expect(check(paths: %w[/billing/v2]).first[:reason]).to eq(:unknown)
  end

  it "ignores deleted routes and routes on other connections" do
    route("gone", paths: %w[/billing]).update!(deleted_at: Time.current)
    create(:kong_entity, entity_type: "route", data: { "paths" => %w[/billing] })
    expect(check(paths: %w[/billing])).to be_empty
  end

  it "includes routes waiting in the open changeset" do
    changeset = create(:changeset, kong_connection: connection)
    create(:change_plan, changeset: changeset, kong_connection: connection, operation: "create", entity_type: "route",
      status: "pending", after: { "name" => "queued", "paths" => %w[/billing] })
    expect(check(paths: %w[/billing], changeset: changeset).map { _1[:route_name] }).to include("queued")
  end
end
