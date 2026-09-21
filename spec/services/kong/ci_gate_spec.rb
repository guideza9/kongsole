require "rails_helper"

RSpec.describe Kong::CiGate do
  describe ".check" do
    it "passes a clean diff that doesn't touch the admin path or delete too much" do
      deck_diff = { "changes" => [ { "name" => "payments-api", "change" => "update" } ] }

      result = described_class.check(deck_diff: deck_diff, admin_path_names: [ "admin-api" ])

      expect(result).to be_passed
      expect(result.reasons).to eq([])
    end

    it "blocks a diff that touches an admin-path entity" do
      deck_diff = { "changes" => [ { "name" => "admin-api", "change" => "update" } ] }

      result = described_class.check(deck_diff: deck_diff, admin_path_names: [ "admin-api" ])

      expect(result).not_to be_passed
      expect(result.reasons.join).to match(/admin path/)
    end

    it "blocks a diff that deletes more entities than the threshold" do
      deck_diff = { "changes" => [
        { "name" => "a", "change" => "delete" },
        { "name" => "b", "change" => "delete" },
        { "name" => "c", "change" => "delete" },
        { "name" => "d", "change" => "delete" }
      ] }

      result = described_class.check(deck_diff: deck_diff, admin_path_names: [], delete_threshold: 3)

      expect(result).not_to be_passed
      expect(result.reasons.join).to match(/deletes 4 entities/)
    end

    it "allows the delete threshold to be configured" do
      deck_diff = { "changes" => [
        { "name" => "a", "change" => "delete" },
        { "name" => "b", "change" => "delete" }
      ] }

      result = described_class.check(deck_diff: deck_diff, admin_path_names: [], delete_threshold: 1)

      expect(result).not_to be_passed
    end

    it "treats a blank deck_diff as no changes at all" do
      result = described_class.check(deck_diff: nil, admin_path_names: [ "admin-api" ])

      expect(result).to be_passed
    end
  end

  describe "against real decK --json-output (M5c)" do
    def fixture(name)
      JSON.parse(File.read(Rails.root.join("spec/fixtures/deck", name)))
    end

    it "passes a real diff that only creates something" do
      result = described_class.check(deck_diff: fixture("gateway_diff_creating.json"), admin_path_names: [ "admin-api" ])

      expect(result).to be_passed
      expect(result.reasons).to eq([])
    end

    it "does not count creations or updates as deletions" do
      diff = fixture("gateway_diff_deleting.json")

      result = described_class.check(deck_diff: diff, admin_path_names: [], delete_threshold: 4)

      expect(result).to be_passed
    end

    it "counts the deleting bucket against the threshold" do
      result = described_class.check(deck_diff: fixture("gateway_diff_deleting.json"), admin_path_names: [], delete_threshold: 3)

      expect(result).not_to be_passed
      expect(result.reasons.join).to match(/deletes 4 entities, over the threshold of 3/)
    end

    it "blocks a real diff that touches an admin-path entity, whichever bucket it is in" do
      result = described_class.check(deck_diff: fixture("gateway_diff_deleting.json"), admin_path_names: [ "admin-api" ], delete_threshold: 99)

      expect(result).not_to be_passed
      expect(result.reasons.join).to match(/admin path/)
    end

    it "still accepts the flat shape earlier plans stored" do
      legacy = { "changes" => [ { "name" => "a", "change" => "delete" }, { "name" => "b", "change" => "update" } ] }

      result = described_class.check(deck_diff: legacy, admin_path_names: [], delete_threshold: 0)

      expect(result.reasons.join).to match(/deletes 1 entities/)
    end
  end
end
