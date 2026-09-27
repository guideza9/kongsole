require "rails_helper"

RSpec.describe "API export", type: :request do
  let(:connection) { create(:kong_connection, :stored, auth_username: "ro", auth_secret: "pw") }
  let(:raw) { PersonalAccessToken.issue!(operator: "o", issued_by_username: "u", connection_ids: [ connection.id ]).last }
  let(:headers) { { "Authorization" => "Bearer #{raw}" } }

  before { allow(Kong::SchemaCache).to receive(:fetch).and_return(nil) }

  it "exports for a bound stored connection with select_tags, as the agent" do
    allow(Kong::DeckCli).to receive(:dump).and_return("_format_version: \"3.0\"\nservices: []\n")

    get api_v1_exports_path, params: { connection: connection.name, select_tags: %w[managed-by-kongctl] }, headers: headers

    expect(response.parsed_body.keys).to contain_exactly("yaml", "summary", "removed", "env_placeholders", "matched_nothing")
    expect(Kong::DeckCli).to have_received(:dump).with(connection: connection, secret: "pw", select_tags: %w[managed-by-kongctl])
    expect(AuditEvent.last).to have_attributes(actor_kind: "agent", actor_username: "u", actor_operator: "o", operation: "export")
  end

  it "returns the same sanitized file the web page does" do
    allow(Kong::DeckCli).to receive(:dump).and_return(File.read(Rails.root.join("spec/fixtures/deck/export_with_secrets.yaml")))

    get api_v1_exports_path, params: { connection: connection.name, select_tags: %w[managed-by-kongctl] }, headers: headers

    body = response.parsed_body
    expect(body["yaml"]).not_to include("BEGIN PRIVATE KEY", "s3cr3t", "keyauth_credentials", "admin-api")
    expect(body["removed"]).to include(include("type" => "service", "name" => "admin-api", "reason" => "admin_path"))
    expect(body["env_placeholders"]).to include("DECK_CERT_A_EXAMPLE_INTERNAL_KEY")
  end

  it "requires select_tags and never runs decK without them" do
    allow(Kong::DeckCli).to receive(:dump)

    get api_v1_exports_path, params: { connection: connection.name }, headers: headers

    expect(response).to have_http_status(:unprocessable_entity)
    expect(response.parsed_body["error"]).to match(/select_tags/)
    expect(Kong::DeckCli).not_to have_received(:dump)
  end

  it "refuses the admin-path tag" do
    allow(Kong::DeckCli).to receive(:dump)

    get api_v1_exports_path, params: { connection: connection.name, select_tags: %w[kong-admin-path] }, headers: headers

    expect(response).to have_http_status(:unprocessable_entity)
    expect(Kong::DeckCli).not_to have_received(:dump)
  end

  it "says which network problem stopped decK" do
    allow(Kong::DeckCli).to receive(:dump).and_raise(Kong::DeckCli::Unreachable.new("deck gateway dump failed: no such host", kind: :dns))

    get api_v1_exports_path, params: { connection: connection.name, select_tags: %w[a] }, headers: headers

    expect(response).to have_http_status(:bad_gateway)
    expect(response.parsed_body["error"]).to include("no such host")
  end

  it "requires a connection this token is bound to" do
    get api_v1_exports_path, params: { select_tags: %w[a] }, headers: headers

    expect(response).to have_http_status(:unauthorized)
  end
end
