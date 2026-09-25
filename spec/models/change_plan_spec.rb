require "rails_helper"

RSpec.describe ChangePlan do
  it "does not expire while it sits in a changeset (R8.1)" do
    plan = create(:change_plan, expires_at: 1.day.ago, changeset: create(:changeset))
    expect(plan.expired?).to be(false)
    expect(plan).to be_in_changeset
  end

  describe "#entity_label" do
    it "is the entity's name, from before when present" do
      plan = build(:change_plan, before: { "name" => "payments-api" }, after: { "name" => "renamed" })

      expect(plan.entity_label).to eq("payments-api")
    end

    it "falls back to after for a create, where before is empty" do
      plan = build(:change_plan, operation: "create", before: {}, after: { "name" => "orders" })

      expect(plan.entity_label).to eq("orders")
    end

    it "is a target's host:port, which has no name" do
      plan = build(:change_plan, entity_type: "target", before: {}, after: { "target" => "10.0.0.1:8080" })

      expect(plan.entity_label).to eq("10.0.0.1:8080")
    end
  end

  describe "#entity_label for a certificate" do
    it "is the first SNI in sorted order, from the create body" do
      plan = build(:change_plan, entity_type: "certificate", operation: "create", before: {},
        after: { "snis" => %w[b.example a.example], "key" => "{vault://env/x}" })

      expect(plan.entity_label).to eq("a.example")
    end
  end
end
