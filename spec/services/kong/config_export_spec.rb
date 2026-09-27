require "rails_helper"

RSpec.describe Kong::ConfigExport do
  let(:connection) { create(:kong_connection, admin_url: "https://kong.test") }
  let(:dump) { File.read(Rails.root.join("spec/fixtures/deck/export_with_secrets.yaml")) }

  before do
    allow(Kong::DeckCli).to receive(:dump).and_return(dump)
    allow(Kong::SchemaCache).to receive(:fetch).and_return(nil)
  end

  def export(**opts)
    described_class.call(connection: connection, secret: "pw", select_tags: %w[managed-by-kongctl],
      actor_username: "alice", actor_operator: "Alice", **opts)
  end

  it "dumps with the connection's credential, sanitizes, and records the export by digest only" do
    result = export

    expect(Kong::DeckCli).to have_received(:dump).with(connection: connection, secret: "pw", select_tags: %w[managed-by-kongctl])
    expect(result.yaml).not_to include("BEGIN PRIVATE KEY")
    event = AuditEvent.last
    expect(event).to have_attributes(kong_connection: connection, operation: "export", entity_type: "config",
      actor_username: "alice", actor_operator: "Alice", actor_kind: "human")
    expect(event.context).to eq("select_tags" => %w[managed-by-kongctl],
      "sha256" => Digest::SHA256.hexdigest(result.yaml), "bytes" => result.yaml.bytesize)
    expect(event.diff).to eq({})
  end

  it "records nothing for a preview" do
    expect { export(record: false) }.not_to change(AuditEvent, :count)
  end

  it "reads each plugin's secret fields from its schema on this connection" do
    allow(Kong::SchemaCache).to receive(:fetch)
      .and_return({ "fields" => [ { "config" => { "type" => "record", "fields" => [ { "function_name" => { "type" => "string", "referenceable" => true } } ] } } ] })

    expect(export(record: false).yaml).to include('function_name: "${{ env "DECK_PLUGIN_AWS_LAMBDA_FUNCTION_NAME" }}"')
  end

  it "refuses bad tags before decK runs" do
    expect { export(select_tags: %w[kong-admin-path]) }.to raise_error(Kong::ExportSanitizer::Refused)
    expect(Kong::DeckCli).not_to have_received(:dump)
  end
end
