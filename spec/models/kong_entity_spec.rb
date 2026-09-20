require "rails_helper"

RSpec.describe KongEntity do
  describe "#expiry_status" do
    let(:now) { Time.zone.local(2026, 9, 21, 12, 0, 0) }

    def status(not_after)
      build(:kong_entity, not_after: not_after).expiry_status(now)
    end

    it "is nil when there is no not_after (every non-certificate entity)" do
      expect(status(nil)).to be_nil
    end

    it "is expired once not_after has passed, including the instant itself" do
      expect(status(now - 1.second)).to eq("expired")
      expect(status(now)).to eq("expired")
    end

    it "is critical within 7 days, boundary inclusive" do
      expect(status(now + 1.second)).to eq("critical")
      expect(status(now + 7.days)).to eq("critical")
    end

    it "is warning past 7 days and up to 30, boundary inclusive" do
      expect(status(now + 7.days + 1.second)).to eq("warning")
      expect(status(now + 30.days)).to eq("warning")
    end

    it "is ok beyond 30 days" do
      expect(status(now + 30.days + 1.second)).to eq("ok")
    end
  end

  describe ".expiring_within" do
    it "returns active-or-not rows expiring inside the window, expired ones included, ordered by the caller" do
      connection = create(:kong_connection)
      soon = create(:kong_entity, kong_connection: connection, entity_type: "certificate", not_after: 3.days.from_now)
      gone = create(:kong_entity, kong_connection: connection, entity_type: "certificate", not_after: 2.days.ago)
      create(:kong_entity, kong_connection: connection, entity_type: "certificate", not_after: 90.days.from_now)
      create(:kong_entity, kong_connection: connection, entity_type: "service", not_after: nil)

      expect(described_class.expiring_within(30)).to contain_exactly(soon, gone)
    end
  end
end
