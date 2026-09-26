require "rails_helper"

RSpec.describe Kong::PluginSchemaForm do
  let(:schema) do
    { "fields" => [ { "config" => { "type" => "record", "fields" => [
      { "minute" => { "type" => "number", "description" => "Requests per minute." } },
      { "policy" => { "type" => "string", "default" => "local", "one_of" => %w[local cluster redis] } },
      { "hide_client_headers" => { "type" => "boolean", "default" => false, "required" => true } },
      { "header_name" => { "type" => "string", "len_min" => 1 } },
      { "allowed" => { "type" => "set", "elements" => { "type" => "string" } } },
      { "redis" => { "type" => "record", "fields" => [ { "password" => { "type" => "string", "referenceable" => true } } ] } },
      { "api_key" => { "type" => "string", "encrypted" => true, "referenceable" => true } }
    ] } } ] }
  end

  it "maps each top-level config field to a form control" do
    kinds = described_class.fields(schema).to_h { [ _1.name, _1.kind ] }
    expect(kinds).to eq("minute" => :number, "policy" => :enum, "hide_client_headers" => :boolean,
      "header_name" => :string, "allowed" => :list, "redis" => :json, "api_key" => :string)
  end

  it "marks encrypted or referenceable fields as secret" do
    expect(described_class.fields(schema).find { _1.name == "api_key" }.secret).to be(true)
  end

  it "keeps defaults, required and allowed values" do
    policy = described_class.fields(schema).find { _1.name == "policy" }
    expect(policy).to have_attributes(default: "local", one_of: %w[local cluster redis], path: "config.policy")
  end

  it "uses custom help when the metadata gives some" do
    field = described_class.fields(schema, custom_help: { "header_name" => "Header to add." }).find { _1.name == "header_name" }
    expect(field.help).to eq("Header to add.")
  end

  # Review Focus 2: a record nested three deep is edited as JSON at its
  # top-level field -- it never drops out of the form.
  it "turns a deeply nested record into one JSON sub-editor for its top-level field" do
    deep = { "fields" => [ { "config" => { "type" => "record", "fields" => [
      { "redis" => { "type" => "record", "fields" => [
        { "cluster_nodes" => { "type" => "array", "elements" => { "type" => "record", "fields" => [
          { "ip" => { "type" => "string" } }, { "port" => { "type" => "integer" } } ] } } } ] } },
      { "headers" => { "type" => "map", "keys" => { "type" => "string" }, "values" => { "type" => "string", "referenceable" => true } } },
      { "upstreams" => { "type" => "array", "elements" => { "type" => "record", "fields" => [] } } }
    ] } } ] }
    fields = described_class.fields(deep)
    expect(fields.map { [ _1.path, _1.kind ] }).to eq([ [ "config.redis", :json ], [ "config.headers", :json ], [ "config.upstreams", :json ] ])
    expect(fields.find { _1.name == "headers" }.secret).to be(true)
  end

  it "gives a number list and an integer their own kinds, and the description Kong wrote" do
    schema = { "fields" => [ { "config" => { "type" => "record", "fields" => [
      { "status_code" => { "type" => "integer", "required" => true } },
      { "codes" => { "type" => "array", "elements" => { "type" => "integer" } } }
    ] } } ] }
    fields = described_class.fields(schema)
    expect(fields.map(&:kind)).to eq(%i[integer list])
    expect(fields.first).to have_attributes(required: true, secret: false, description: nil, help: nil)
    expect(described_class.fields(self.schema).first.description).to eq("Requests per minute.")
  end

  it "has no fields for a plugin without config, or a schema that is not one" do
    expect(described_class.fields({ "fields" => [ { "protocols" => { "type" => "set" } } ] })).to eq([])
    expect(described_class.fields(nil)).to eq([])
  end
end
