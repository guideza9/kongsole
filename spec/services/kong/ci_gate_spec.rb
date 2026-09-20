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
end
