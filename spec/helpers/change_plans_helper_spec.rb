require "rails_helper"

RSpec.describe ChangePlansHelper, type: :helper do
  let(:plan) { build(:change_plan) }

  describe "#plan_field_summary" do
    it "counts the diff's fields for an update, against the entity's total" do
      # `after` is set here because a factory's own `after { }` is FactoryBot's callback DSL, not an attribute.
      summary = helper.plan_field_summary(build(:change_plan, after: { "id" => "1", "name" => "a", "tags" => [ "x" ], "host" => "h" }))

      expect(summary).to eq(count: 1, label: "field changed", note: "of 4 on the service")
    end

    it "counts every field as added for a create" do
      create_plan = build(:change_plan, operation: "create", before: {}, after: { "name" => "a", "host" => "h" }, diff: {})

      expect(helper.plan_field_summary(create_plan)).to include(count: 2, label: "fields added")
    end

    it "counts every field as removed, and permanent, for a delete" do
      delete_plan = build(:change_plan, :delete, before: { "id" => "1", "name" => "a", "tags" => [] })

      expect(helper.plan_field_summary(delete_plan)).to eq(count: 3, label: "fields removed", note: "Permanent")
    end
  end

  describe "#plan_timestamp" do
    it "renders a UTC stamp that names its zone, with the machine-readable instant alongside" do
      stamp = helper.plan_timestamp(Time.utc(2026, 9, 21, 14, 5))

      expect(stamp).to include("2026-09-21 14:05 UTC")
      expect(stamp).to include('datetime="2026-09-21T14:05:00Z"')
    end

    it "hands the element to the local-time controller, which rewrites it in the viewer's zone" do
      expect(helper.plan_timestamp(Time.utc(2026, 9, 21, 14, 5))).to include('data-controller="local-time"')
    end

    it "converts a zoned time rather than printing its wall clock as UTC" do
      stamp = helper.plan_timestamp(Time.utc(2026, 9, 21, 14, 5).in_time_zone("Asia/Bangkok"))

      expect(stamp).to include("2026-09-21 14:05 UTC")
    end

    it "is nil with no time, so a caller can leave the slot out entirely" do
      expect(helper.plan_timestamp(nil)).to be_nil
    end
  end

  describe "#plan_expiry_summary" do
    it "counts down a live pending plan and stamps it in UTC" do
      summary = helper.plan_expiry_summary(plan)

      expect(summary[:value]).to start_with("in ")
      expect(summary[:note]).to match(/\d{4}-\d{2}-\d{2} \d{2}:\d{2} UTC/)
      expect(summary[:note]).to include("data-controller=\"local-time\"")
      expect(summary[:tone]).to be_nil
    end

    it "warns in the last few minutes" do
      expect(helper.plan_expiry_summary(build(:change_plan, expires_at: 2.minutes.from_now))[:tone]).to eq(:warning)
    end

    it "says Expired, in danger tone, once the plan has lapsed" do
      summary = helper.plan_expiry_summary(build(:change_plan, :expired))

      expect(summary).to include(value: "Expired", tone: :danger)
    end

    it "drops the clock once the plan is no longer pending" do
      summary = helper.plan_expiry_summary(build(:change_plan, status: "applied"))

      expect(summary).to include(value: "Applied", note: "Expiry no longer applies", iso: nil)
    end
  end

  describe "#guardrail_summary" do
    let(:guardrail) { ChangePlansController::Guardrail }

    it "leads with what the operator still has to confirm" do
      list = [ guardrail.new(:pass, "a", ""), guardrail.new(:confirm, "b", ""), guardrail.new(:confirm, "c", "") ]

      expect(helper.guardrail_summary(list)).to eq(value: "2 to confirm", note: "1 of 3 passed", tone: nil)
    end

    it "flags a heads-up in warning tone when nothing needs confirming" do
      list = [ guardrail.new(:pass, "a", ""), guardrail.new(:warn, "b", "") ]

      expect(helper.guardrail_summary(list)).to include(value: "1 to review", tone: :warning)
    end

    it "says All clear when every check passed" do
      expect(helper.guardrail_summary([ guardrail.new(:pass, "a", "") ])).to include(value: "All clear")
    end
  end
end
