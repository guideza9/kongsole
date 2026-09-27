require "rails_helper"

RSpec.describe "Export", type: :request do
  include SignInHelper
  let(:connection) { create(:kong_connection, admin_url: "https://kong.test", project_env: create(:project_env, select_tags: %w[managed-by-kongctl])) }
  let(:dump) { File.read(Rails.root.join("spec/fixtures/deck/export_with_secrets.yaml")) }

  before do
    sign_in_to(connection, access: :ro)
    allow(Kong::DeckCli).to receive(:dump).and_return(dump)
    allow(Kong::SchemaCache).to receive(:fetch).and_return(nil)
  end

  it "offers the connection's own select tags to start from" do
    get new_export_path
    expect(response).to have_http_status(:ok)
    expect(response.body).to include('value="managed-by-kongctl"')
  end

  it "previews the sanitized file without storing it" do
    written = -> { Dir.glob(Rails.root.join("{tmp,storage}/**/*.{yaml,yml}")).to_h { [ _1, File.mtime(_1) ] } }
    before = written.call
    post preview_export_path, params: { select_tags: "managed-by-kongctl" }
    expect(response.body).to include("_info")
    expect(response.body).not_to include("BEGIN PRIVATE KEY")
    expect(written.call).to eq(before)
    expect(AuditEvent.where(operation: "export")).to be_empty
  end

  it "downloads the same bytes as the preview and records who exported, without the content" do
    post export_path, params: { select_tags: "managed-by-kongctl" }
    expect(response.headers["Content-Disposition"]).to match(/attachment; filename=".+-managed-by-kongctl-\d{8}-\d{4}\.yaml"/)
    expect(response.media_type).to eq("application/yaml")
    event = AuditEvent.last
    expect(event).to have_attributes(operation: "export", entity_type: "config")
    expect(event.context["sha256"]).to eq(Digest::SHA256.hexdigest(response.body))
    expect(event.context.to_json).not_to include("service")
  end

  it "reads several tags, comma- or space-separated, in the order given" do
    post export_path, params: { select_tags: "managed-by-kongctl, team-a" }
    expect(Kong::DeckCli).to have_received(:dump).with(hash_including(select_tags: %w[managed-by-kongctl team-a]))
    expect(response.headers["Content-Disposition"]).to include("managed-by-kongctl+team-a")
  end

  it "refuses the admin-path tag" do
    post preview_export_path, params: { select_tags: "kong-admin-path" }
    expect(response).to have_http_status(:unprocessable_entity)
    expect(Kong::DeckCli).not_to have_received(:dump)
  end

  it "explains a Kong this machine cannot reach instead of failing" do
    allow(Kong::DeckCli).to receive(:dump).and_raise(Kong::DeckCli::Unreachable.new("deck gateway dump failed: no such host", kind: :dns))
    post preview_export_path, params: { select_tags: "managed-by-kongctl" }
    expect(response).to have_http_status(:bad_gateway)
    expect(response.body).to include(I18n.t("hints.errors.network_dns_failed.cause"))
  end

  describe "the page (R7.5)" do
    let(:page) { Nokogiri::HTML(response.body) }

    it "warns that a sync deletes what the file lacks, before the Download button" do
      post preview_export_path, params: { select_tags: "managed-by-kongctl" }
      warning = response.body.index(ERB::Util.html_escape(I18n.t("hints.risks.export_sync.title")))
      download = response.body.index(">Download")
      expect(warning).to be_present
      expect(download).to be_present
      expect(warning).to be < download
    end

    it "lists what was removed or replaced as a table with column headers" do
      post preview_export_path, params: { select_tags: "managed-by-kongctl" }
      table = page.at_css("table")
      expect(table.css("th[scope=col]").map(&:text)).to eq(%w[Type Name Why])
      expect(table.text).to include("admin-api", "partner-x")
    end

    it "gives the placeholder variables as a list to copy" do
      post preview_export_path, params: { select_tags: "managed-by-kongctl" }
      block = page.at_css("[data-controller=copy]")
      expect(block.at_css("[data-copy-target=source]").text.split("\n")).to include("DECK_CERT_A_EXAMPLE_INTERNAL_KEY")
      expect(block.at_css("button[data-action='copy#copy']")).to be_present
    end

    it "puts the YAML in a focusable, labelled region that scrolls" do
      post preview_export_path, params: { select_tags: "managed-by-kongctl" }
      yaml = page.at_css("pre.export-yaml")
      expect(yaml["tabindex"]).to eq("0")
      expect(yaml["aria-label"]).to be_present
      expect(yaml.css(".export-yaml__line").first.text).to start_with("# Exported by Kongsole")
    end

    it "says loudly when the tags matched nothing" do
      allow(Kong::DeckCli).to receive(:dump).and_return("_format_version: \"3.0\"\n")
      post preview_export_path, params: { select_tags: "no-such-tag" }
      notice = page.css(".risk-notice").find { _1.text.include?(I18n.t("hints.risks.export_matched_nothing.title", env: connection.name, tags: "no-such-tag")) }
      expect(notice).to be_present
      expect(notice["class"]).to include("danger")
    end

    it "is in the primary nav once logged in" do
      get new_export_path
      link = page.at_css("nav[aria-label=Primary] a[href='#{new_export_path}']")
      expect(link.text).to eq("Export")
      expect(link["aria-current"]).to eq("page")
    end
  end

  it "sends a visitor who is not logged in back to log in" do
    delete logout_path
    get new_export_path
    expect(response).to redirect_to(root_path)
  end
end
