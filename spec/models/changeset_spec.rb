require "rails_helper"

RSpec.describe Changeset do
  let(:connection) { create(:kong_connection, project_env: create(:project_env, name: "uat", apply_mode: "pr", source: "registry")) }

  it "keeps a single open changeset per connection" do
    first = described_class.open_for!(connection: connection, actor_username: "a", actor_operator: nil)
    expect(described_class.open_for!(connection: connection, actor_username: "b", actor_operator: nil)).to eq(first)
    expect { described_class.create!(kong_connection: connection, status: "open", actor_username: "c") }
      .to raise_error(ActiveRecord::RecordNotUnique)
  end

  it "refuses a direct-mode connection" do
    direct = create(:kong_connection)
    expect { described_class.open_for!(connection: direct, actor_username: "a", actor_operator: nil) }
      .to raise_error(Kong::ChangeGuardrails::Violation, /PR mode/)
  end

  it "lists its pending items in their order" do
    changeset = create(:changeset, kong_connection: connection)
    second = create(:change_plan, changeset: changeset, kong_connection: connection, apply_mode: "pr", position: 2)
    first = create(:change_plan, changeset: changeset, kong_connection: connection, apply_mode: "pr", position: 1)
    create(:change_plan, changeset: changeset, kong_connection: connection, apply_mode: "pr", position: 3, status: "cancelled")
    expect(changeset.items).to eq([ first, second ])
    expect(changeset).to be_open
  end
end
