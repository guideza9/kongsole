require "rails_helper"

RSpec.describe ChangePlan do
  it "does not expire while it sits in a changeset (R8.1)" do
    plan = create(:change_plan, expires_at: 1.day.ago, changeset: create(:changeset))
    expect(plan.expired?).to be(false)
    expect(plan).to be_in_changeset
  end

  # R4.10: a direct-mode plugin plan's real secrets, kept apart and encrypted.
  describe "sealed secrets" do
    let(:sealed) { { "after" => { "config" => { "aws_secret" => "sk_PLAIN" } }, "diff" => { "operation" => "create" } } }
    let(:plan) do
      create(:change_plan, entity_type: "plugin", after: { "config" => { "aws_secret" => Kong::Redactor::MARK } },
        sealed_secrets: sealed.to_json)
    end

    it "is encrypted at rest" do
      raw = ChangePlan.connection.select_value("SELECT sealed_secrets FROM change_plans WHERE id = #{plan.id}")
      expect(raw).to be_present
      expect(raw).not_to include("sk_PLAIN")
    end

    it "gives the applier the real body and everyone else the redacted one" do
      expect(plan.unsealed_after["config"]["aws_secret"]).to eq("sk_PLAIN")
      expect(plan.after["config"]["aws_secret"]).to eq(Kong::Redactor::MARK)
      expect(plan.unsealed_diff).to eq("operation" => "create")
      expect(create(:change_plan).unsealed_after).to eq(create(:change_plan).after)
    end

    it "is cleared once the plan stops being pending" do
      %w[applied failed cancelled].each do |status|
        fresh = create(:change_plan, entity_type: "plugin", sealed_secrets: sealed.to_json)
        fresh.update!(status: status)
        expect(fresh.reload.sealed_secrets).to be_nil
      end
    end

    it "says when a body it would send still holds a redaction mark" do
      expect(build(:change_plan, operation: "create", after: { "config" => { "k" => Kong::Redactor::MARK } }).redacted_payload?).to be(true)
      expect(build(:change_plan, operation: "update",
        diff: { "config" => { "from" => { "k" => Kong::Redactor::MARK }, "to" => { "k" => "new" } } }).redacted_payload?).to be(false)
      expect(build(:change_plan, operation: "update",
        diff: { "config" => { "from" => {}, "to" => { "k" => Kong::Redactor::MARK } } }).redacted_payload?).to be(true)
    end
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
