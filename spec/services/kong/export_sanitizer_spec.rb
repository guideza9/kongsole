require "rails_helper"

RSpec.describe Kong::ExportSanitizer do
  let(:connection) { create(:kong_connection) }
  let(:text) { File.read(Rails.root.join("spec/fixtures/deck/export_with_secrets.yaml")) }
  let(:secret_paths) { ->(name) { name == "aws-lambda" ? [ %w[config aws_secret] ] : nil } }

  before do
    create(:kong_entity, kong_connection: connection, entity_type: "consumer", name: "jakkapat", is_admin_path: true)
  end

  def run(tags = %w[managed-by-kongctl]) = described_class.call(text, connection: connection, select_tags: tags, secret_paths_for: secret_paths)

  it "leaves no credential, private key or plugin secret in the file" do
    yaml = run.yaml
    %w[basicauth_credentials keyauth_credentials jwt_secrets hmacauth_credentials BEGIN\ PRIVATE\ KEY s3cr3t xyz].each do |needle|
      expect(yaml).not_to include(needle)
    end
  end

  it "drops admin-path entities by tag and by the read-model" do
    result = run
    expect(result.yaml).not_to include("admin-api", "jakkapat")
    expect(result.removed).to include(include(type: "service", name: "admin-api", reason: :admin_path),
      include(type: "consumer", name: "jakkapat", reason: :admin_path))
  end

  it "replaces secrets with decK env placeholders and lists them" do
    result = run
    expect(result.yaml).to include('"${{ env "DECK_PLUGIN_AWS_LAMBDA_AWS_SECRET" }}"')
    expect(result.yaml).to include("{vault://env/cert-a-key}")
    expect(result.env_placeholders).to include("DECK_PLUGIN_AWS_LAMBDA_AWS_SECRET")
  end

  it "fails closed on a plugin whose schema is unknown" do
    expect(run.yaml).to include('"${{ env "DECK_PLUGIN_TEAM_AUTH_SIGNING_SECRET" }}"')
  end

  it "always writes _info.select_tags and the snapshot header" do
    yaml = run(%w[managed-by-kongctl team-a]).yaml
    expect(yaml).to start_with("# Exported by Kongsole")
    expect(YAML.safe_load(yaml.gsub(/"\$\{\{ env "(DECK_[A-Z0-9_]+)" \}\}"/, '"\1"')).dig("_info", "select_tags")).to eq(%w[managed-by-kongctl team-a])
  end

  it "is byte-for-byte stable for the same input" do
    expect(run.yaml).to eq(run.yaml)
  end

  it "refuses no tags, the admin-path tag, or a malformed tag" do
    [ [], %w[kong-admin-path], [ "bad tag" ] ].each do |tags|
      expect { run(tags) }.to raise_error(described_class::Refused)
    end
  end

  it "flags an export that matched nothing" do
    result = described_class.call("_format_version: \"3.0\"\n", connection: connection, select_tags: %w[x], secret_paths_for: secret_paths)
    expect(result.matched_nothing).to be(true)
  end

  # Review Focus 3: a real PEM becomes a placeholder named after the certificate.
  it "replaces a certificate's PEM private key with a placeholder, never the PEM" do
    result = run
    expect(result.yaml).to include('key: "${{ env "DECK_CERT_A_EXAMPLE_INTERNAL_KEY" }}"')
    expect(result.removed).to include(type: "certificate", name: "a.example.internal", reason: :private_key)
  end

  it "drops a top-level plugin scoped to an admin-path service, and everything nested under it" do
    result = run
    expect(result.yaml).not_to include("request-termination", "admin-api-rw", "hide_credentials")
    expect(result.removed).to include(include(type: "plugin", name: "request-termination", reason: :admin_path))
  end

  it "records each credential it drops, by consumer" do
    expect(run.removed).to include(
      { type: "keyauth_credential", name: "partner-x", reason: :credential },
      { type: "jwt_secret", name: "partner-x", reason: :credential },
      { type: "hmacauth_credential", name: "partner-x", reason: :credential }
    )
  end

  it "keeps a secret header map's shape, one placeholder per header, when the schema is unknown" do
    yaml = run.yaml
    expect(yaml).not_to include("log-fixture-token")
    expect(yaml).to include('Authorization: "${{ env "DECK_PLUGIN_HTTP_LOG_HEADERS_AUTHORIZATION" }}"')
  end

  it "gives two plugins with the same secret field their own variables" do
    result = run
    expect(result.env_placeholders).to include("DECK_PLUGIN_AWS_LAMBDA_AWS_SECRET", "DECK_PLUGIN_AWS_LAMBDA_AWS_SECRET_2")
    expect(result.yaml).not_to include("route-level")
  end

  it "keeps a non-secret value whose name only looks secret when it is not a string" do
    doc = <<~YAML
      _format_version: "3.0"
      services:
      - name: s
        plugins:
        - config:
            auth_timeout: 5
            hide_credentials: true
          name: custom-thing
    YAML
    yaml = described_class.call(doc, connection: connection, select_tags: %w[x], secret_paths_for: secret_paths).yaml
    expect(yaml).to include("auth_timeout: 5", "hide_credentials: true")
  end

  it "counts what the file holds, per entity type" do
    expect(run.summary).to include("service" => 1, "route" => 1, "consumer" => 1, "certificate" => 2)
  end
end
