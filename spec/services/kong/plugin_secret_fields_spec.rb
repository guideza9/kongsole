require "rails_helper"

RSpec.describe Kong::PluginSecretFields do
  let(:schema) do
    { "fields" => [
      { "name" => { "type" => "string" } },
      { "config" => { "type" => "record", "fields" => [
        { "aws_key" => { "type" => "string", "encrypted" => true, "referenceable" => true } },
        { "timeout" => { "type" => "number" } },
        { "redis" => { "type" => "record", "fields" => [
          { "password" => { "type" => "string", "referenceable" => true } },
          { "host" => { "type" => "string" } }
        ] } }
      ] } }
    ] }
  end

  it "lists every encrypted or referenceable field at any depth" do
    expect(described_class.paths(schema)).to contain_exactly(%w[config aws_key], %w[config redis password])
  end

  # Kong 3.7's http-log and opentelemetry mark `referenceable` on the map's
  # values, not on `headers` itself -- an Authorization header lives there.
  it "lists a map or array whose values are marked, so the whole collection is redacted" do
    schema = { "fields" => [ { "config" => { "type" => "record", "fields" => [
      { "headers" => { "type" => "map", "keys" => { "type" => "string" },
                       "values" => { "type" => "string", "referenceable" => true } } },
      { "tokens" => { "type" => "array", "elements" => { "type" => "string", "encrypted" => true } } },
      { "names" => { "type" => "array", "elements" => { "type" => "string" } } }
    ] } } ] }
    expect(described_class.paths(schema)).to contain_exactly(%w[config headers], %w[config tokens])
  end

  # A custom plugin may hold an array (or map) of records with a secret
  # inside; the path cannot index into it, so the whole collection goes.
  it "lists an array or map of records that has a secret field somewhere inside" do
    schema = { "fields" => [ { "config" => { "type" => "record", "fields" => [
      { "upstreams" => { "type" => "array", "elements" => { "type" => "record", "fields" => [
        { "url" => { "type" => "string" } }, { "token" => { "type" => "string", "referenceable" => true } } ] } } },
      { "by_team" => { "type" => "map", "values" => { "type" => "record", "fields" => [
        { "creds" => { "type" => "record", "fields" => [ { "secret" => { "type" => "string", "encrypted" => true } } ] } } ] } } },
      { "plain" => { "type" => "array", "elements" => { "type" => "record", "fields" => [ { "url" => { "type" => "string" } } ] } } }
    ] } } ] }
    expect(described_class.paths(schema)).to contain_exactly(%w[config upstreams], %w[config by_team])
  end

  describe "#fetch" do
    let(:connection) { create(:kong_connection, admin_url: "https://kong.test", kong_version: "3.7.1") }
    let(:client) { Kong::Client.new(connection: connection, secret: "pw") }

    it "returns nil when the schema cannot be read, so the caller fails closed" do
      stub_request(:get, "https://kong.test/schemas/plugins/aws-lambda").to_return(status: 503, body: "{}")
      expect(described_class.new.fetch(client: client, plugin_name: "aws-lambda")).to be_nil
    end

    # R4.1: one copy of the schema per connection and Kong version, shared by
    # every sync run and the plugin form (Kong::SchemaCache).
    it "reads the schema through the connection's schema cache" do
      stub = stub_request(:get, "https://kong.test/schemas/plugins/aws-lambda").to_return(status: 200, body: schema.to_json)
      2.times { expect(described_class.new.fetch(client: client, plugin_name: "aws-lambda")).to include(%w[config aws_key]) }
      expect(stub).to have_been_requested.once
      expect(KongSchema.digest_for(connection: connection, kind: "plugin", name: "aws-lambda")).to be_present
    end
  end
end
