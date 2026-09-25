require "rails_helper"

# R8.6: what the reviewer (CAB) reads -- in the PR and in the commit.
RSpec.describe Kong::PrBody do
  let(:changeset) { create(:changeset) }
  let!(:billing) do
    create(:change_plan, changeset: changeset, kong_connection: changeset.kong_connection, apply_mode: "pr", position: 1,
      operation: "create", entity_type: "service", target_kong_id: nil, before: {}, after: { "name" => "billing" })
  end
  let!(:ledger) do
    create(:change_plan, changeset: changeset, kong_connection: changeset.kong_connection, apply_mode: "pr", position: 2,
      operation: "delete", entity_type: "route", before: { "name" => "ledger-v1" }, after: {})
  end
  let(:deck_diff) do
    { "changes" => { "creating" => [ { "kind" => "service", "name" => "billing" } ], "updating" => [],
      "deleting" => [ { "kind" => "route", "name" => "ledger-v1" } ] } }
  end
  let(:gate) { Kong::CiGate::Result.new(passed: true, reasons: []) }

  it "lists every item in order, sums decK's diff, gives the gate's answer and names the changeset" do
    body = described_class.markdown(changeset, deck_diff: deck_diff, gate: gate, operator: "somchai@example.com")

    expect(body).to include("| 1 | create | service | billing |", "| 2 | delete | route | ledger-v1 |")
    expect(body).to include("creating 1", "updating 0", "deleting 1")
    expect(body).to include("CI gate: Clear")
    expect(body).to include("Changeset: #{changeset.id}", "Plans: #{billing.id}, #{ledger.id}")
    expect(body.lines.last.strip).to eq("Changed-by: somchai@example.com")
  end

  it "says why the gate blocked" do
    blocked = Kong::CiGate::Result.new(passed: false, reasons: [ "deletes 4 entities, over the threshold of 3" ])
    expect(described_class.markdown(changeset, deck_diff: deck_diff, gate: blocked, operator: nil))
      .to include("CI gate: Blocked", "deletes 4 entities, over the threshold of 3")
  end

  it "leaves out the trailer when no operator was given" do
    expect(described_class.markdown(changeset, deck_diff: deck_diff, gate: gate, operator: nil)).not_to include("Changed-by")
    expect(described_class.commit_message(changeset, operator: nil)).not_to include("Changed-by")
  end

  it "writes a commit whose trailers git can read" do
    message = described_class.commit_message(changeset, operator: "somchai@example.com")
    subject, blank, *rest = message.lines.map(&:chomp)
    expect(subject).to eq("Changeset #{changeset.id}: 2 changes to #{changeset.kong_connection.name}")
    expect(blank).to eq("")
    expect(rest).to include("- create service billing", "- delete route ledger-v1")
    expect(rest.last(3)).to eq([ "Changeset: #{changeset.id}", "Plans: #{billing.id}, #{ledger.id}", "Changed-by: somchai@example.com" ])
  end
end
