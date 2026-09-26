require "rails_helper"

# A private key pasted into a certificate form or sent as an API attribute
# must never reach the Rails log. Parameter names in play: the web form's
# `payload_json`, and the API's nested `attributes[key]` / `attributes[key_alt]`.
RSpec.describe "Parameter log filtering" do
  let(:filter) { ActiveSupport::ParameterFilter.new(Rails.application.config.filter_parameters) }

  it "filters the JSON editor's payload" do
    expect(filter.filter("payload_json" => "{\"key\":\"-----BEGIN PRIVATE KEY-----\"}")["payload_json"]).to eq("[FILTERED]")
  end

  it "filters a nested API key and key_alt" do
    filtered = filter.filter("attributes" => { "key" => "PEM", "key_alt" => "PEM", "tags" => [ "ok" ] })

    expect(filtered["attributes"]).to eq({ "key" => "[FILTERED]", "key_alt" => "[FILTERED]", "tags" => [ "ok" ] })
  end

  # R4 final review: the plugin form sends each config field on its own, and a
  # JSON sub-field (http-log's headers, a redis record) can hold a secret the
  # field name says nothing about -- an Authorization header, a password.
  it "filters every config value of the plugin form, whatever the field is called" do
    filtered = filter.filter("plugin_name" => "http-log", "plugin" => { "config" => {
      "headers" => "{\"Authorization\":\"Basic abc\"}", "redis" => "{\"password\":\"hunter2\"}", "http_endpoint" => "http://logs" },
      "enabled" => "1" })

    expect(filtered["plugin"]["config"].values).to all(eq("[FILTERED]"))
    expect(filtered["plugin"]["enabled"]).to eq("1")
    expect(filtered["plugin_name"]).to eq("http-log")
  end

  it "does not blank unrelated params such as the type or connection" do
    expect(filter.filter("type" => "certificate", "connection" => "dev")).to eq({ "type" => "certificate", "connection" => "dev" })
  end
end
