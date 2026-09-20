require "rails_helper"

RSpec.describe Kong::EntityQuery do
  let(:connection) { create(:kong_connection) }

  def entity(name:, tags: [], updated_at: Time.current, created_at: Time.current)
    create(:kong_entity, kong_connection: connection, entity_type: "service",
      name: name, tags: tags, kong_updated_at: updated_at, kong_created_at: created_at)
  end

  describe "filtering" do
    it "filters by tags= with AND semantics" do
      match = entity(name: "a", tags: %w[payment core])
      entity(name: "b", tags: %w[payment])
      entity(name: "c", tags: %w[core])

      result = described_class.new(connection: connection, type: "service", params: { tags: %w[payment core] }).call

      expect(result[:data]).to contain_exactly(match)
    end

    it "filters by tags_any= with OR semantics" do
      a = entity(name: "a", tags: %w[beta])
      b = entity(name: "b", tags: %w[canary])
      entity(name: "c", tags: %w[core])

      result = described_class.new(connection: connection, type: "service", params: { tags_any: %w[beta canary] }).call

      expect(result[:data]).to contain_exactly(a, b)
    end

    it "filters by tags_none= excluding any match" do
      keep = entity(name: "a", tags: %w[core])
      entity(name: "b", tags: %w[deprecated])

      result = described_class.new(connection: connection, type: "service", params: { tags_none: %w[deprecated] }).call

      expect(result[:data]).to contain_exactly(keep)
    end

    it "filters by q= as a substring match on name" do
      match = entity(name: "payments-api")
      entity(name: "orders-api")

      result = described_class.new(connection: connection, type: "service", params: { q: "payments" }).call

      expect(result[:data]).to contain_exactly(match)
    end

    it "filters by updated_after=, excluding rows updated earlier" do
      recent = entity(name: "recent", updated_at: 1.day.ago)
      entity(name: "stale", updated_at: 20.days.ago)

      result = described_class.new(connection: connection, type: "service", params: { updated_after: 7.days.ago }).call

      expect(result[:data]).to contain_exactly(recent)
    end

    it "never returns soft-deleted entities" do
      entity(name: "gone").update!(deleted_at: Time.current)

      result = described_class.new(connection: connection, type: "service", params: {}).call

      expect(result[:data]).to be_empty
    end

    it "raises InvalidSort for a sort key outside the allowlist" do
      expect {
        described_class.new(connection: connection, type: "service", params: { sort: "admin_url" }).call
      }.to raise_error(Kong::EntityQuery::InvalidSort)
    end
  end

  describe "keyset pagination" do
    it "returns exactly `limit` rows and signals has_more at the page boundary" do
      5.times { |n| entity(name: "svc-#{n}", updated_at: n.days.ago) }

      result = described_class.new(connection: connection, type: "service", params: { limit: 3 }).call

      expect(result[:data].size).to eq(3)
      expect(result[:has_more]).to eq(true)
      expect(result[:next_cursor]).to be_present
    end

    it "does not signal has_more when every row fits in one page" do
      3.times { |n| entity(name: "svc-#{n}") }

      result = described_class.new(connection: connection, type: "service", params: { limit: 10 }).call

      expect(result[:has_more]).to eq(false)
      expect(result[:next_cursor]).to be_nil
    end

    it "walks every row exactly once across pages, including ties on the sort column" do
      # all five share the same updated_at -- the id tiebreaker must still
      # produce a stable, non-overlapping, non-skipping walk.
      same_time = 1.day.ago
      created = 5.times.map { |n| entity(name: "svc-#{n}", updated_at: same_time) }

      seen = []
      cursor = nil
      loop do
        result = described_class.new(connection: connection, type: "service", params: { limit: 2, cursor: cursor }).call
        seen.concat(result[:data])
        break unless result[:has_more]
        cursor = result[:next_cursor]
      end

      expect(seen.map(&:id)).to match_array(created.map(&:id))
      expect(seen.map(&:id).uniq.size).to eq(5)
    end

    it "rejects a cursor that was tampered with" do
      entity(name: "a")
      expect {
        described_class.new(connection: connection, type: "service", params: { cursor: "not-a-real-cursor" }).call
      }.to raise_error(Kong::EntityQuery::InvalidCursor)
    end

    it "rejects a cursor reused after the filters changed" do
      entity(name: "a", tags: %w[payment])
      entity(name: "b", tags: %w[payment])

      first = described_class.new(connection: connection, type: "service", params: { tags: %w[payment], limit: 1 }).call

      expect {
        described_class.new(connection: connection, type: "service", params: { tags: %w[other], limit: 1, cursor: first[:next_cursor] }).call
      }.to raise_error(Kong::EntityQuery::InvalidCursor)
    end

    it "rejects a cursor reused with a different sort" do
      entity(name: "a")
      entity(name: "b")

      first = described_class.new(connection: connection, type: "service", params: { sort: "name", limit: 1 }).call

      expect {
        described_class.new(connection: connection, type: "service", params: { sort: "-name", limit: 1, cursor: first[:next_cursor] }).call
      }.to raise_error(Kong::EntityQuery::InvalidCursor)
    end
  end
end
