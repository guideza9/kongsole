require "rails_helper"

RSpec.describe ProjectOverview do
  let(:project) { create(:project, key: "project-a") }
  let!(:dev) { create(:project_env, project: project, name: "dev", position: 1) }
  let!(:uat) { create(:project_env, project: project, name: "uat", position: 2) }
  let!(:dev_conn) { create(:kong_connection, project_env: dev, last_status: "ok", last_connected_at: Time.utc(2026, 9, 26, 9, 12)) }

  it "lists envs in order with counts per entity type from the read-model" do
    create_list(:kong_entity, 2, kong_connection: dev_conn, entity_type: "service")
    create(:kong_entity, kong_connection: dev_conn, entity_type: "route")
    create(:kong_entity, kong_connection: dev_conn, entity_type: "service", deleted_at: Time.current)

    rows = described_class.new(project).rows

    expect(rows.map { _1.env.name }).to eq(%w[dev uat])
    expect(rows.first.counts).to eq("service" => 2, "route" => 1, "plugin" => 0, "consumer" => 0, "upstream" => 0, "certificate" => 0)
    expect(rows.first.status).to eq("ok")
    expect(rows.first.last_connected_at).to eq(Time.utc(2026, 9, 26, 9, 12))
  end

  it "takes the sync time from the latest synced entity, deleted ones included" do
    create(:kong_entity, kong_connection: dev_conn, synced_at: Time.utc(2026, 9, 25, 17, 40))
    create(:kong_entity, kong_connection: dev_conn, synced_at: Time.utc(2026, 9, 26, 9, 14), deleted_at: Time.current)

    expect(described_class.new(project).rows.first.synced_at).to eq(Time.utc(2026, 9, 26, 9, 14))
  end

  it "says never synced -- not zero -- for a connection with nothing in the read-model, and nil for an env without one" do
    rows = described_class.new(project).rows

    expect(rows.first.synced_at).to be_nil
    expect(rows.last.connection).to be_nil
    expect(rows.last.synced_at).to be_nil
  end

  it "never calls Kong" do
    described_class.new(project).rows
    expect(a_request(:any, //)).not_to have_been_made
  end
end
