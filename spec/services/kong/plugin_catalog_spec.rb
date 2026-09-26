require "rails_helper"

RSpec.describe Kong::PluginCatalog do
  let(:connection) do
    create(:kong_connection, plugins_available: { "available_on_server" => {
      "rate-limiting" => { "version" => "3.7.1", "priority" => 910 },
      "team-auth" => { "version" => "0.3.0", "priority" => 1005 },
      "team-headers" => { "version" => "1.0.0", "priority" => 800 } } })
  end
  let(:dir) { Rails.root.join("spec/fixtures/custom_plugins") }

  it "lists what the node loaded, bundled and custom apart" do
    entries = described_class.for(connection, metadata_dir: dir)
    expect(entries.map { [ _1.name, _1.custom ] }).to eq([ [ "rate-limiting", false ], [ "team-auth", true ], [ "team-headers", true ] ])
  end

  it "reads a custom plugin's description from its metadata file" do
    entry = described_class.for(connection, metadata_dir: dir).find { _1.name == "team-auth" }
    expect(entry.summary).to eq("Checks the team's signed header before proxying.")
  end

  it "says plainly when a custom plugin has no description" do
    entry = described_class.for(connection, metadata_dir: dir).find { _1.name == "team-headers" }
    expect(entry.summary).to be_nil
  end

  it "never reads a metadata path outside the directory" do
    evil = create(:kong_connection, plugins_available: { "available_on_server" => { "../../secrets" => {} } })
    expect { described_class.for(evil, metadata_dir: dir) }.not_to raise_error
    expect(described_class.for(evil, metadata_dir: dir).first.summary).to be_nil
  end

  it "carries the node's version and priority, and a custom plugin's docs link and field help" do
    entry = described_class.for(connection, metadata_dir: dir).find { _1.name == "team-auth" }
    expect(entry).to have_attributes(version: "0.3.0", priority: 1005,
      docs_url: "https://git.example.internal/team/kong-plugins/team-auth",
      field_help: { "upstream_header" => "Header the plugin adds before proxying." })
  end

  it "describes a bundled plugin from hints.plugins.<name>.summary" do
    allow(I18n).to receive(:t).and_call_original
    allow(I18n).to receive(:t).with("hints.plugins.rate-limiting.summary", default: nil).and_return("Caps requests per window.")
    entry = described_class.for(connection, metadata_dir: dir).find { _1.name == "rate-limiting" }
    expect(entry.summary).to eq("Caps requests per window.")
  end

  it "lists nothing for a connection that has not read its node yet" do
    expect(described_class.for(create(:kong_connection, plugins_available: {}), metadata_dir: dir)).to eq([])
  end
end
