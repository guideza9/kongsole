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

    it "passes the real no-change diff decK always emits" do
      no_change = JSON.parse('{"changes":{"creating":[],"updating":[],"deleting":[]},"summary":{"creating":0,"updating":0,"deleting":0,"total":0},"warnings":[],"errors":[]}')

      result = described_class.check(deck_diff: no_change, admin_path_names: [ "admin-api" ], delete_threshold: 0)

      expect(result).to be_passed
    end

    it "blocks a blank diff rather than reading missing output as no changes" do
      [ {}, nil, { "summary" => {} } ].each do |blank|
        result = described_class.check(deck_diff: blank, admin_path_names: [ "admin-api" ])

        expect(result).not_to be_passed
        expect(result.reasons.join).to match(/the decK diff has no `changes` -- refusing to treat missing output as no changes/)
      end
    end
  end

  describe "against real decK --json-output (M5c)" do
    def fixture(name)
      JSON.parse(File.read(Rails.root.join("spec/fixtures/deck", name)))
    end

    it "passes a real diff that only creates something" do
      result = described_class.check(deck_diff: fixture("gateway_diff_creating.json"), admin_path_names: [ "admin-api" ], delete_threshold: 0)

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

    it "blocks a diff whose changes hash has a bucket the gate does not know" do
      diff = { "changes" => { "creating" => [], "removing" => [ { "name" => "x" } ] } }

      result = described_class.check(deck_diff: diff, admin_path_names: [], delete_threshold: 99)

      expect(result).not_to be_passed
      expect(result.reasons.join).to match(/diff shape was not recognised/)
    end

    it "blocks a bucket that is not an array, and an entry that is not a hash" do
      bad_bucket = { "changes" => { "deleting" => "svc-a" } }
      bad_entry = { "changes" => { "deleting" => [ "svc-a" ] } }

      [ bad_bucket, bad_entry ].each do |diff|
        result = described_class.check(deck_diff: diff, admin_path_names: [], delete_threshold: 99)

        expect(result).not_to be_passed
        expect(result.reasons.join).to match(/diff shape was not recognised/)
      end
    end

    it "blocks a diff in which decK reported errors, scrubbing any private key" do
      pem = "-----BEGIN PRIVATE KEY-----
abc
-----END PRIVATE KEY-----"
      diff = fixture("gateway_diff_creating.json").merge("errors" => [ "cannot reach admin api", pem ])

      result = described_class.check(deck_diff: diff, admin_path_names: [], delete_threshold: 99)

      expect(result).not_to be_passed
      expect(result.reasons.join).to match(/decK reported errors in the diff: cannot reach admin api/)
      expect(result.reasons.join).not_to include("BEGIN PRIVATE KEY")
    end

    it "passes a diff with an empty changes hash or empty buckets" do
      [ { "changes" => {} }, { "changes" => { "creating" => [], "updating" => [], "deleting" => [] }, "errors" => [] } ].each do |diff|
        result = described_class.check(deck_diff: diff, admin_path_names: [ "admin-api" ], delete_threshold: 0)

        expect(result).to be_passed
      end
    end
  end
end
