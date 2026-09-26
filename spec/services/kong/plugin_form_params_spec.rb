require "rails_helper"

RSpec.describe Kong::PluginFormParams do
  let(:fields) { Kong::PluginSchemaForm.fields(schema) }
  let(:schema) { JSON.parse(File.read(Rails.root.join("spec/fixtures/schemas/rate_limiting_like.json"))) }

  it "coerces types and fills schema defaults for blank fields" do
    attrs, errors = described_class.call(fields: fields, params: { "config" => { "minute" => "60", "policy" => "",
      "hide_client_headers" => "1", "allowed" => "a\nb\n", "redis" => "{\"password\":\"{vault://env/redis-pw}\"}" } })
    expect(errors).to be_empty
    expect(attrs["config"]).to include("minute" => 60, "policy" => "local", "hide_client_headers" => true,
      "allowed" => %w[a b], "redis" => { "password" => "{vault://env/redis-pw}" })
  end

  it "reports bad numbers and bad JSON on their own fields" do
    _attrs, errors = described_class.call(fields: fields, params: { "config" => { "minute" => "abc", "redis" => "{" } })
    expect(errors.keys).to contain_exactly("config.minute", "config.redis")
  end

  it "leaves a blank secret out so an edit keeps Kong's current value" do
    attrs, = described_class.call(fields: fields, params: { "config" => { "api_key" => "" } })
    expect(attrs["config"]).not_to have_key("api_key")
  end

  # Review Focus 3: a field left blank sends the schema's default, never "" or nil.
  it "sends the default for a field left out or blank, and nothing for one with no default" do
    attrs, errors = described_class.call(fields: fields, params: { "config" => { "header_name" => "  " } })
    expect(errors).to be_empty
    expect(attrs["config"]).to eq("policy" => "local", "hide_client_headers" => false)
  end

  # Review Focus 4: only a plain decimal is a number.
  it "refuses 1e3 as a number, and keeps a decimal as one" do
    _attrs, errors = described_class.call(fields: fields, params: { "config" => { "minute" => "1e3" } })
    expect(errors["config.minute"]).to be_present
    attrs, = described_class.call(fields: fields, params: { "config" => { "minute" => "0.5" } })
    expect(attrs["config"]["minute"]).to eq(0.5)
  end

  it "refuses a value outside an enum, and a checkbox left off is false" do
    attrs, errors = described_class.call(fields: fields, params: { "config" => { "policy" => "global", "hide_client_headers" => "0" } })
    expect(errors["config.policy"].first).to include("local, cluster, redis")
    expect(attrs["config"]["hide_client_headers"]).to be(false)
  end

  it "never echoes a bad JSON value in its error" do
    _attrs, errors = described_class.call(fields: fields, params: { "config" => { "redis" => "{\"password\": sk_live_9" } })
    expect(errors["config.redis"].join).not_to include("sk_live_9")
  end

  it "keeps an integer list as integers, and says which line is not one" do
    fields = Kong::PluginSchemaForm.fields({ "fields" => [ { "config" => { "type" => "record", "fields" => [
      { "codes" => { "type" => "array", "elements" => { "type" => "integer" } } } ] } } ] })
    attrs, = described_class.call(fields: fields, params: { "config" => { "codes" => "429\n503" } })
    expect(attrs["config"]["codes"]).to eq([ 429, 503 ])
    _attrs, errors = described_class.call(fields: fields, params: { "config" => { "codes" => "429\nfive" } })
    expect(errors["config.codes"].first).to include("line 2")
  end

  it "says a required field with no default is required" do
    fields = Kong::PluginSchemaForm.fields({ "fields" => [ { "config" => { "type" => "record", "fields" => [
      { "status_code" => { "type" => "integer", "required" => true } } ] } } ] })
    _attrs, errors = described_class.call(fields: fields, params: { "config" => {} })
    expect(errors).to eq("config.status_code" => [ "is required" ])
  end

  it "reads enabled, tags and protocols beside the config" do
    attrs, = described_class.call(fields: fields, params: { "enabled" => "0", "tags" => "team-a, team-b\nteam-c",
      "protocols" => [ "", "https" ], "config" => {} })
    expect(attrs).to include("enabled" => false, "tags" => %w[team-a team-b team-c], "protocols" => %w[https])
  end
end
