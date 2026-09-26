require "rails_helper"

RSpec.describe Kong::PluginChain do
  let(:connection) do
    create(:kong_connection, plugins_available: { "available_on_server" => {
      "rate-limiting" => { "priority" => 910 }, "key-auth" => { "priority" => 1250 }, "cors" => { "priority" => 2000 },
      "acl" => { "priority" => 950 } } })
  end
  let(:service) { create(:kong_entity, kong_connection: connection, entity_type: "service", name: "billing") }
  let(:route) { create(:kong_entity, kong_connection: connection, entity_type: "route", name: "billing-v1", parent_type: "service", parent_kong_id: service.kong_id) }

  def plugin(name, scope: {}, enabled: true, config: {})
    create(:kong_entity, kong_connection: connection, entity_type: "plugin", name: name, enabled: enabled,
      data: { "name" => name, "enabled" => enabled, "config" => config }.merge(scope))
  end

  def chain
    described_class.for(connection: connection, route: route, service: service)
  end

  it "orders plugins by Kong priority, highest first, across scopes" do
    plugin("rate-limiting")
    plugin("key-auth", scope: { "service" => { "id" => service.kong_id } })
    plugin("cors", scope: { "route" => { "id" => route.kong_id } })

    steps, = chain

    expect(steps.map { _1.plugin.name }).to eq(%w[cors key-auth rate-limiting])
    expect(steps.map(&:scope)).to eq(%w[route service global])
    expect(steps.map(&:priority)).to eq([ 2000, 1250, 910 ])
  end

  it "keeps only the most specific instance of the same plugin, naming what it replaces" do
    plugin("rate-limiting")
    plugin("rate-limiting", scope: { "route" => { "id" => route.kong_id } })

    steps, = chain

    expect(steps.map(&:scope)).to eq(%w[route])
    expect(steps.first.overrides).to eq(%w[global])
  end

  it "lets the wider instance run when the narrower one is disabled (Review Focus 1)" do
    plugin("rate-limiting")
    plugin("rate-limiting", scope: { "route" => { "id" => route.kong_id } }, enabled: false)

    steps, = chain

    expect(steps.map { [ _1.scope, _1.enabled ] }).to contain_exactly([ "global", true ], [ "route", false ])
  end

  it "ignores plugins on other routes and services" do
    other = create(:kong_entity, kong_connection: connection, entity_type: "route")
    plugin("cors", scope: { "route" => { "id" => other.kong_id } })
    expect(chain.first).to be_empty
  end

  it "lists consumer-scoped plugins apart, naming the consumer" do
    consumer = create(:kong_entity, kong_connection: connection, entity_type: "consumer", name: "partner-x")
    plugin("rate-limiting", scope: { "consumer" => { "id" => consumer.kong_id } })

    steps, consumer_steps = chain

    expect(steps).to be_empty
    expect(consumer_steps.map { [ _1.scope, _1.consumer ] }).to eq([ [ "consumer", "partner-x" ] ])
  end

  it "shows disabled plugins as disabled rather than hiding them" do
    plugin("cors", enabled: false)
    expect(chain.first.map(&:enabled)).to eq([ false ])
  end

  it "puts a plugin the node has not loaded last, without a priority" do
    plugin("team-auth")
    plugin("cors")
    steps, = chain
    expect(steps.map { [ _1.plugin.name, _1.priority ] }).to eq([ [ "cors", 2000 ], [ "team-auth", nil ] ])
  end

  it "carries each plugin's effect" do
    plugin("key-auth")
    expect(chain.first.first.effect).to have_attributes(kind: :may_stop, status: 401)
  end
end
