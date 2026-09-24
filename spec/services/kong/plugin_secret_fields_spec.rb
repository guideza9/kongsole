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

  it "returns nil when the schema cannot be read, so the caller fails closed" do
    client = instance_double(Kong::Client)
    allow(client).to receive(:get).and_raise(Kong::Client::UpstreamUnavailable.new("down"))
    expect(described_class.new.fetch(client: client, plugin_name: "aws-lambda")).to be_nil
  end
end
