require "rails_helper"

RSpec.describe ApplicationHelper, type: :helper do
  describe "#highlight_json" do
    it "wraps keys, strings, numbers, booleans, and null in their own class" do
      html = helper.highlight_json({ "name" => "svc", "port" => 8080, "enabled" => true, "ca" => nil })

      expect(html).to include('<span class="json-key">&quot;name&quot;:</span>')
      expect(html).to include('<span class="json-string">&quot;svc&quot;</span>')
      expect(html).to include('<span class="json-number">8080</span>')
      expect(html).to include('<span class="json-bool">true</span>')
      expect(html).to include('<span class="json-null">null</span>')
    end

    it "escapes HTML-unsafe characters inside a string value rather than emitting them raw" do
      html = helper.highlight_json({ "host" => "<script>alert(1)</script>", "note" => 'a "quoted" & <tag>' })

      expect(html).not_to include("<script>")
      expect(html).to include("&lt;script&gt;")
      expect(html).to include("&amp;")
    end

    it "produces a safe buffer so ERB does not re-escape the generated spans" do
      html = helper.highlight_json({ "a" => 1 })
      expect(html).to be_html_safe
    end

    it "leaves JSON structure (braces, brackets, commas, indentation) untouched" do
      html = helper.highlight_json({ "tags" => %w[a b] })
      expect(html).to include("{\n")
      expect(html).to include("[\n")
      expect(html).to include(",\n")
    end
  end

  describe "#connection_policy_labels" do
    it "spells the registry tokens out as words" do
      connection = build(:kong_connection, apply_mode: "pr", access_level: "ro", credential_kind: "shared")

      expect(helper.connection_policy_labels(connection)).to eq([ "PR mode", "Read-only", "Shared credential" ])
    end

    it "shows only what is known before a login probe" do
      expect(helper.connection_policy_labels(build(:kong_connection, apply_mode: "direct", credential_kind: nil))).to eq([ "Direct apply" ])
    end
  end

  describe "#env_badge" do
    it "renders a solid chip by rank for uat/prod, ignoring color_tag" do
      prod = build(:kong_connection, :prod, color_tag: "green")
      uat = build(:kong_connection, name: "uat", env: "uat", rank: 2, color_tag: "green")

      expect(helper.env_badge(prod)).to include("chip-env", "env-prod")
      expect(helper.env_badge(uat)).to include("chip-env", "env-uat")
      expect(helper.env_badge(prod)).not_to include("chip-ok", "chip-danger")
    end

    it "spells the environment out ahead of the connection name at uat/prod" do
      prod = build(:kong_connection, :prod, name: "kong-prod-admin")
      uat = build(:kong_connection, name: "kong-uat", env: "uat", rank: 2)

      expect(Nokogiri::HTML.fragment(helper.env_badge(prod)).text).to eq("PROD·kong-prod-admin")
      expect(Nokogiri::HTML.fragment(helper.env_badge(uat)).text).to eq("UAT·kong-uat")
    end

    it "does not say the environment twice when the connection is named for it" do
      prod = build(:kong_connection, :prod, name: "prod")

      expect(Nokogiri::HTML.fragment(helper.env_badge(prod)).text).to eq("PROD")
    end

    it "keeps the quiet dot + name chip below rank 2, toned by color_tag" do
      html = helper.env_badge(build(:kong_connection, name: "dev-1", color_tag: "green"))

      expect(html).not_to include("chip-env")
      expect(html).to include("chip-ok")
      expect(Nokogiri::HTML.fragment(html).text).to eq("dev-1")
    end

    it "falls back to the neutral tone for an unknown color_tag" do
      expect(helper.env_badge(build(:kong_connection, color_tag: "teal"))).to include("chip-neutral")
    end
  end

  describe "#primary_nav_current?" do
    it "marks Pending PRs on the plan list and Entities on a plan's review page, never both" do
      allow(helper).to receive(:controller_name).and_return("change_plans")

      allow(helper).to receive(:action_name).and_return("index")
      expect(helper.primary_nav_current?(:pending)).to be(true)
      expect(helper.primary_nav_current?(:entities)).to be(false)

      allow(helper).to receive(:action_name).and_return("show")
      expect(helper.primary_nav_current?(:pending)).to be(false)
      expect(helper.primary_nav_current?(:entities)).to be(true)
    end
  end

  describe "#status_badge" do
    it "covers a change plan's, a token's and the admin path's states with the same tones" do
      expect(helper.status_badge("applied")).to include("chip-ok").and include("Applied")
      expect(helper.status_badge("failed")).to include("chip-danger")
      expect(helper.status_badge("pending")).to include("chip-neutral")
      expect(helper.status_badge("revoked")).to include("chip-danger")
      expect(helper.status_badge("guarded")).to include("chip-ok")
      expect(helper.status_badge("unknown")).to include("chip-neutral")
    end

    it "maps a status to a tone class and never restates a colour" do
      expect(helper.status_badge("ok")).to include("chip-ok")
      expect(helper.status_badge("unauthorized")).to include("chip-danger")
      expect(helper.status_badge("rate_limited")).to include("chip-warning")
      expect(helper.status_badge(nil)).to include("chip-neutral").and include("Never connected")
      expect(helper.status_badge("ok")).not_to include("style=")
    end
  end

  it "keeps every colour in the stylesheet: the helpers hold no hex literal" do
    source = File.read(Rails.root.join("app/helpers/application_helper.rb"))

    expect(source.scan(/#[0-9a-fA-F]{6}\b/)).to be_empty
  end

  describe "certificate helpers (M5b)" do
    it "labels the three types" do
      expect(helper.entity_type_label("certificate")).to eq("Certificates")
      expect(helper.entity_type_label("certificate", count: 1)).to eq("Certificate")
      expect(helper.entity_type_label("ca_certificate")).to eq("CA certificates")
      expect(helper.entity_type_label("sni", count: 1)).to eq("SNI")
    end

    it "renders an expiry badge per tier, and a dash when there is nothing to expire" do
      %w[expired critical warning ok].each do |status|
        entity = build(:kong_entity, not_after: 1.day.from_now)
        allow(entity).to receive(:expiry_status).and_return(status)
        expect(helper.expiry_badge(entity)).to include(status.capitalize)
      end
      expect(helper.expiry_badge(build(:kong_entity, not_after: nil))).to include("—")
    end

    it "describes expiry in words, past and future" do
      expect(helper.expiry_when(build(:kong_entity, not_after: 12.days.from_now))).to eq("in 12 days")
      expect(helper.expiry_when(build(:kong_entity, not_after: 3.days.ago))).to eq("3 days ago")
      expect(helper.expiry_when(build(:kong_entity, not_after: nil))).to be_nil
    end
  end

  describe "#env_display_name" do
    it "spells the environment out for consequence copy" do
      expect(helper.env_display_name(build(:kong_connection, env: "prod"))).to eq("Production")
      expect(helper.env_display_name(build(:kong_connection, env: "dev"))).to eq("Development")
    end

    it "leaves an initialism as an initialism rather than inventing prose" do
      expect(helper.env_display_name(build(:kong_connection, env: "uat"))).to eq("UAT")
      expect(helper.env_display_name(build(:kong_connection, env: "sit"))).to eq("SIT")
    end

    it "falls back to the token itself rather than rendering a blank sentence" do
      connection = build(:kong_connection)
      allow(connection).to receive(:env).and_return("staging")

      expect(helper.env_display_name(connection)).to eq("staging")
    end
  end

  describe "#nav_link_to" do
    it "marks the current link with aria-current=page" do
      html = helper.nav_link_to("Entities", "/entities", current: true, class: "x")

      expect(html).to include('aria-current="page"')
      expect(html).to include('href="/entities"').and include('class="x"').and include(">Entities</a>")
    end

    it "omits aria-current entirely when the link is not current, never rendering aria-current=false" do
      html = helper.nav_link_to("Audit", "/audit_events", current: false)

      expect(html).not_to include("aria-current")
    end
  end

  describe "#primary_nav_current?" do
    it "maps a section to the controllers that live inside it" do
      allow(helper).to receive(:controller_name).and_return("plugins")

      expect(helper.primary_nav_current?(:entities)).to be(true)
      expect(helper.primary_nav_current?(:connections)).to be(false)
    end

    it "keeps Connections current on the login form" do
      allow(helper).to receive(:controller_name).and_return("sessions")

      expect(helper.primary_nav_current?(:connections)).to be(true)
    end
  end
end
