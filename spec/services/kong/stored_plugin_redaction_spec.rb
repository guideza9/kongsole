require "rails_helper"

RSpec.describe Kong::StoredPluginRedaction do
  it "re-redacts plugin rows, plan snapshots and audit diffs already on disk (fail-closed rules)" do
    connection = create(:kong_connection)
    entity = create(:kong_entity, kong_connection: connection, entity_type: "plugin",
      data: { "name" => "http-log", "config" => { "headers" => { "Authorization" => "Basic abc" } } })
    plan = create(:change_plan, :expired, kong_connection: connection, entity_type: "plugin",
      after: { "name" => "aws-lambda", "config" => { "aws_secret" => "s3cr3t" } })
    event = create(:audit_event, kong_connection: connection, entity_type: "plugin",
      diff: { "config" => { "from" => { "client_secret" => "old" }, "to" => { "client_secret" => "new" } } })

    counts = described_class.call

    expect(entity.reload.data.to_json).not_to include("Basic abc")
    expect(plan.reload.after.to_json).not_to include("s3cr3t")
    expect(event.reload.diff.to_json).not_to match(/"old"|"new"/)
    expect(counts).to eq(entities: 1, plans: 1, audit_events: 1)
  end

  # Applying it would send "[REDACTED]" to Kong as the secret.
  it "leaves a plan that can still be applied untouched" do
    plan = create(:change_plan, entity_type: "plugin", status: "pending", expires_at: 10.minutes.from_now,
      after: { "name" => "aws-lambda", "config" => { "aws_secret" => "s3cr3t" } })

    counts = described_class.call

    expect(plan.reload.after.dig("config", "aws_secret")).to eq("s3cr3t")
    expect(counts[:plans]).to eq(0)
  end
end
