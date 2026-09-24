require "rails_helper"

RSpec.describe Kong::EntitySchema do
  let(:connection) { create(:kong_connection, admin_url: "https://kong.test") }
  let(:client) { Kong::Client.new(connection: connection, secret: "pw") }

  it "flattens Kong's upstream schema into reference rows, without Kong-managed fields" do
    stub_request(:get, "https://kong.test/schemas/upstreams").to_return(status: 200, body: { fields: [
      { id: { type: "string", auto: true } },
      { name: { type: "string", required: true } },
      { algorithm: { type: "string", default: "round-robin", one_of: %w[consistent-hashing least-connections round-robin] } }
    ] }.to_json)

    rows = described_class.fields(client: client, entity_type: "upstream")
    expect(rows.map { _1[:name] }).to eq(%w[name algorithm])
    expect(rows.last).to include(default: "round-robin", one_of: include("least-connections"))
  end

  it "returns nil when Kong cannot be read, so the page falls back to hints alone" do
    stub_request(:get, "https://kong.test/schemas/upstreams").to_return(status: 503, body: "{}")
    expect(described_class.fields(client: client, entity_type: "upstream")).to be_nil
  end

  it "keeps a record's own fields as nested rows" do
    stub_request(:get, "https://kong.test/schemas/upstreams").to_return(status: 200, body: { fields: [
      { healthchecks: { type: "record", fields: [ { threshold: { type: "number", default: 0 } } ] } }
    ] }.to_json)

    row = described_class.fields(client: client, entity_type: "upstream").first
    expect(row).to include(name: "healthchecks", type: "record")
    expect(row[:nested]).to eq([ { name: "threshold", type: "number", required: false, default: 0, one_of: nil, nested: [] } ])
  end
end
