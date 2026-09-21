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
end
