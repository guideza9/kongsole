require "rails_helper"

RSpec.describe ChangePlan do
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
end
