require "rails_helper"

RSpec.describe Kong::DeckRenderer do
  describe ".parse" do
    it "builds a fresh skeleton when there is no YAML yet" do
      doc = described_class.parse(nil, select_tags: [ "managed-by-kongctl" ])

      expect(doc).to eq(
        "_format_version" => "3.0",
        "_info" => { "select_tags" => [ "managed-by-kongctl" ] },
        "services" => []
      )
    end

    it "always overwrites select_tags from the connection, even if the file disagrees (rule ข -- mandatory)" do
      doc = described_class.parse("_info:\n  select_tags: [stale-tag]\nservices: []\n", select_tags: [ "managed-by-kongctl" ])

      expect(doc["_info"]["select_tags"]).to eq([ "managed-by-kongctl" ])
    end
  end

  describe ".apply_change" do
    def plan(operation:, before: {}, after: {})
      ChangePlan.new(operation: operation, before: before, after: after)
    end

    it "appends a new service on create, stripping Kong-managed fields" do
      doc = described_class.parse(nil, select_tags: [])

      described_class.apply_change(doc, plan(
        operation: "create",
        after: { "id" => "abc", "created_at" => 1, "updated_at" => 2, "name" => "payments-api", "tags" => [ "payment" ] }
      ))

      expect(doc["services"]).to eq([ { "name" => "payments-api", "tags" => [ "payment" ] } ])
    end

    it "merges attributes into the matched service on update" do
      doc = described_class.parse(nil, select_tags: [])
      doc["services"] << { "name" => "payments-api", "tags" => [ "payment" ], "enabled" => true }

      described_class.apply_change(doc, plan(
        operation: "update",
        before: { "name" => "payments-api" },
        after: { "id" => "abc", "name" => "payments-api", "tags" => %w[payment deprecated], "enabled" => true }
      ))

      expect(doc["services"]).to eq([ { "name" => "payments-api", "tags" => %w[payment deprecated], "enabled" => true } ])
    end

    it "removes the matched service on delete" do
      doc = described_class.parse(nil, select_tags: [])
      doc["services"] << { "name" => "payments-api" }

      described_class.apply_change(doc, plan(operation: "delete", before: { "name" => "payments-api" }))

      expect(doc["services"]).to eq([])
    end

    it "raises rather than silently no-op when the update target isn't in the YAML" do
      doc = described_class.parse(nil, select_tags: [])

      expect {
        described_class.apply_change(doc, plan(operation: "update", before: { "name" => "missing" }, after: { "name" => "missing" }))
      }.to raise_error(ArgumentError, /no service named missing/)
    end
  end

  describe ".serialize" do
    it "round-trips byte-for-byte: serialize(parse(serialize(doc))) == serialize(doc)" do
      doc = described_class.parse(nil, select_tags: [ "managed-by-kongctl", "team-payments" ])
      doc["services"] << { "name" => "payments-api", "url" => "http://payments:8080", "tags" => [ "payment" ], "enabled" => true }
      doc["services"] << { "name" => "orders-api", "url" => "http://orders:8080", "tags" => [] }

      first_pass = described_class.serialize(doc)
      second_pass = described_class.serialize(described_class.parse(first_pass, select_tags: [ "managed-by-kongctl", "team-payments" ]))

      expect(second_pass).to eq(first_pass)
    end

    it "orders each service's keys with name first, then the rest alphabetically" do
      doc = described_class.parse(nil, select_tags: [])
      doc["services"] << { "url" => "http://payments:8080", "name" => "payments-api", "enabled" => true }

      expect(described_class.serialize(doc)).to eq(<<~YAML)
        _format_version: '3.0'
        _info:
          select_tags:
        services:
          - name: payments-api
            enabled: true
            url: http://payments:8080
      YAML
    end
  end
end
