require "rails_helper"

RSpec.describe EntitiesHelper, type: :helper do
  describe "#sync_freshness" do
    it "says how long ago, with the exact UTC instant on hover, and stays quiet while fresh" do
      html = helper.sync_freshness(5.minutes.ago, "dev")

      expect(html).to include("Synced from dev ").and include("5 minutes ago")
      expect(html).to include('title="').and include(" UTC")
      expect(html).to include("</time>.")
      expect(html).not_to include("text-warning")
    end

    it "says in words, and in warning ink, that an old sync may be out of date" do
      html = helper.sync_freshness(3.hours.ago, "dev")

      expect(html).to include("text-warning").and include("about 3 hours ago").and include("may be out of date")
    end

    it "says a connection that never synced has nothing listed, and how to fix that" do
      expect(helper.sync_freshness(nil, "dev")).to include("Never synced from dev").and include("Sync")
    end
  end

  describe "#certificate_lifespan" do
    let(:now) { Time.utc(2026, 9, 1, 12) }

    def cert(not_before:, not_after:)
      build(:kong_entity, entity_type: "certificate", not_after: not_after,
        data: { "_metadata" => { "not_before" => not_before&.iso8601 } })
    end

    it "is the fraction of validity that has passed, toned by the expiry status" do
      span = helper.certificate_lifespan(cert(not_before: now - 270.days, not_after: now + 90.days), now)

      expect(span).to include(percent: 75, tone: "ok")
    end

    it "pins an expired certificate at 100% and the danger tone" do
      span = helper.certificate_lifespan(cert(not_before: now - 400.days, not_after: now - 1.day), now)

      expect(span).to include(percent: 100, tone: "danger")
    end

    it "is nil, never a guess, when either end is unknown" do
      expect(helper.certificate_lifespan(cert(not_before: nil, not_after: now + 1.day), now)).to be_nil
      expect(helper.certificate_lifespan(cert(not_before: now - 1.day, not_after: nil), now)).to be_nil
    end

    it "is nil when the cached not_before is garbage" do
      entity = build(:kong_entity, entity_type: "certificate", not_after: now + 1.day, data: { "_metadata" => { "not_before" => "garbage" } })

      expect(helper.certificate_lifespan(entity, now)).to be_nil
    end
  end

  describe "#route_match" do
    it "reads methods, hosts and paths, and is nil for any other type" do
      route = build(:kong_entity, entity_type: "route", data: { "methods" => [ "GET" ], "paths" => [ "/a" ] })

      expect(helper.route_match(route)).to eq(methods: [ "GET" ], hosts: [], paths: [ "/a" ])
      expect(helper.route_match(build(:kong_entity))).to be_nil
    end
  end

  describe "#plugin_scope_sentence" do
    it "says how far each scope reaches" do
      expect(helper.plugin_scope_sentence(kind: "global")).to include("every request")
      expect(helper.plugin_scope_sentence(kind: "consumer")).to include("consumer")
    end
  end
end
