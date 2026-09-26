require "rails_helper"

RSpec.describe Kong::SchemaCache do
  include ActiveSupport::Testing::TimeHelpers

  let(:connection) { create(:kong_connection, admin_url: "https://kong.test", kong_version: "3.7.1") }
  let(:client) { Kong::Client.new(connection: connection, secret: "pw") }
  let(:schema) { { "fields" => [ { "config" => { "type" => "record", "fields" => [] } } ] } }

  it "fetches once and serves from the cache for the same Kong version" do
    stub = stub_request(:get, "https://kong.test/schemas/plugins/rate-limiting").to_return(status: 200, body: schema.to_json)
    2.times { described_class.fetch(connection: connection, client: client, kind: "plugin", name: "rate-limiting") }
    expect(stub).to have_been_requested.once
  end

  it "refetches after the Kong version changes" do
    stub = stub_request(:get, "https://kong.test/schemas/plugins/rate-limiting").to_return(status: 200, body: schema.to_json)
    described_class.fetch(connection: connection, client: client, kind: "plugin", name: "rate-limiting")
    connection.update_columns(kong_version: "3.8.0")
    described_class.fetch(connection: connection, client: client, kind: "plugin", name: "rate-limiting")
    expect(stub).to have_been_requested.twice
  end

  it "serves a stale copy when Kong is down, and nil when it never had one" do
    stub_request(:get, "https://kong.test/schemas/plugins/acl").to_return(status: 503, body: "{}")
    expect(described_class.fetch(connection: connection, client: client, kind: "plugin", name: "acl")).to be_nil

    stub_request(:get, "https://kong.test/schemas/plugins/cors").to_return(status: 200, body: schema.to_json)
    described_class.fetch(connection: connection, client: client, kind: "plugin", name: "cors")
    travel 25.hours do
      stub_request(:get, "https://kong.test/schemas/plugins/cors").to_return(status: 503, body: "{}")
      expect(described_class.fetch(connection: connection, client: client, kind: "plugin", name: "cors")).to eq(schema)
    end
  end

  # The plugin form explains why Kong could not be read (R3), so it asks for
  # the error rather than nil when there is no copy to fall back on.
  it "raises Kong's error when strict and no copy exists, and still serves a stale copy" do
    stub_request(:get, "https://kong.test/schemas/plugins/acl").to_return(status: 503, body: "{}")
    expect { described_class.fetch(connection: connection, client: client, kind: "plugin", name: "acl", strict: true) }
      .to raise_error(Kong::Client::UpstreamUnavailable)

    KongSchema.create!(kong_connection: connection, kind: "plugin", name: "acl", kong_version: "3.6.0", digest: "d",
      body: schema, fetched_at: 2.days.ago)
    expect(described_class.fetch(connection: connection, client: client, kind: "plugin", name: "acl", strict: true)).to eq(schema)
  end

  it "refetches a copy older than a day" do
    stub = stub_request(:get, "https://kong.test/schemas/plugins/cors").to_return(status: 200, body: schema.to_json)
    described_class.fetch(connection: connection, client: client, kind: "plugin", name: "cors")
    travel(25.hours) { described_class.fetch(connection: connection, client: client, kind: "plugin", name: "cors") }
    expect(stub).to have_been_requested.twice
  end

  it "reads an entity type's schema from /schemas/<name>, apart from a plugin of the same name" do
    stub_request(:get, "https://kong.test/schemas/upstreams").to_return(status: 200, body: { "fields" => [] }.to_json)
    expect(described_class.fetch(connection: connection, client: client, kind: "entity", name: "upstreams")).to eq("fields" => [])
    expect(KongSchema.where(kong_connection: connection, kind: "entity", name: "upstreams").count).to eq(1)
  end

  it "gives the same digest for the same schema, whatever the key order" do
    stub_request(:get, "https://kong.test/schemas/plugins/a").to_return(status: 200, body: '{"x":1,"y":2}')
    stub_request(:get, "https://kong.test/schemas/plugins/b").to_return(status: 200, body: '{"y":2,"x":1}')
    %w[a b].each { described_class.fetch(connection: connection, client: client, kind: "plugin", name: _1) }
    expect(KongSchema.digest_for(connection: connection, kind: "plugin", name: "a"))
      .to eq(KongSchema.digest_for(connection: connection, kind: "plugin", name: "b"))
    expect(KongSchema.digest_for(connection: connection, kind: "plugin", name: "none")).to be_nil
  end
end

RSpec.describe Kong::EntitySchema do
  it "reads an entity type's schema through the schema cache" do
    connection = create(:kong_connection, admin_url: "https://kong.test", kong_version: "3.7.1")
    client = Kong::Client.new(connection: connection, secret: "pw")
    stub = stub_request(:get, "https://kong.test/schemas/upstreams")
      .to_return(status: 200, body: { fields: [ { name: { type: "string" } } ] }.to_json)
    2.times { described_class.fields(client: client, entity_type: "upstream") }
    expect(stub).to have_been_requested.once
  end
end
