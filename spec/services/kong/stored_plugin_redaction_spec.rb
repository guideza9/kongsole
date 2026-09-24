require "rails_helper"

RSpec.describe Kong::StoredPluginRedaction do
  it "re-redacts plugin rows, plan snapshots and audit diffs already on disk (fail-closed rules)" do
    connection = create(:kong_connection)
    entity = create(:kong_entity, kong_connection: connection, entity_type: "plugin",
      data: { "name" => "http-log", "config" => { "headers" => { "Authorization" => "Basic abc" } } })
    plan = create(:change_plan, kong_connection: connection, entity_type: "plugin",
      after: { "name" => "aws-lambda", "config" => { "aws_secret" => "s3cr3t" } })
    event = create(:audit_event, kong_connection: connection, entity_type: "plugin",
      diff: { "config" => { "from" => { "client_secret" => "old" }, "to" => { "client_secret" => "new" } } })

    counts = described_class.call

    expect(entity.reload.data.to_json).not_to include("Basic abc")
    expect(plan.reload.after.to_json).not_to include("s3cr3t")
    expect(event.reload.diff.to_json).not_to match(/"old"|"new"/)
    expect(counts).to eq(entities: 1, plans: 1, audit_events: 1)
  end
end
