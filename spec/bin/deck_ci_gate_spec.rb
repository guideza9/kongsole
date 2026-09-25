require "rails_helper"

# R8.6: CI checks a pushed changeset branch with the same gate Kongsole ran
# before the push -- the changeset's recorded decK diff, the connection's
# admin-path names and the project's delete threshold.
RSpec.describe "bin/deck-ci-gate" do
  let(:script) { Rails.root.join("bin", "deck-ci-gate").to_s }

  def run_gate(*args)
    saved = ARGV.dup
    ARGV.replace(args.map(&:to_s))
    status = nil
    out = StringIO.new
    err = StringIO.new
    $stdout, $stderr = out, err
    begin
      load script
    rescue SystemExit => e
      status = e.status
    ensure
      $stdout, $stderr = STDOUT, STDERR
      ARGV.replace(saved)
    end
    [ status, out.string, err.string ]
  end

  def changeset_with(deleting:, threshold: 3)
    changeset = create(:changeset, status: "submitted", branch: "kongctl/changeset-1",
      deck_diff: { "changes" => { "creating" => [], "updating" => [],
        "deleting" => Array.new(deleting) { |i| { "kind" => "service", "name" => "svc-#{i}" } } } })
    changeset.kong_connection.project.update!(delete_threshold: threshold)
    changeset
  end

  it "passes a changeset whose diff stays within the project's threshold" do
    changeset = changeset_with(deleting: 2, threshold: 3)
    status, out, = run_gate("--changeset", changeset.id)
    expect(status).to eq(0)
    expect(out).to include("PASS", "changeset #{changeset.id}")
  end

  it "blocks one that deletes more than the project's threshold, and says why" do
    changeset = changeset_with(deleting: 2, threshold: 1)
    status, _, err = run_gate("--changeset", changeset.id)
    expect(status).to eq(1)
    expect(err).to include("BLOCKED", "over the threshold of 1")
  end

  it "still takes a single plan id, as before" do
    plan = create(:change_plan, apply_mode: "pr", deck_diff: { "changes" => { "creating" => [], "updating" => [], "deleting" => [] } })
    status, out, = run_gate(plan.id)
    expect(status).to eq(0)
    expect(out).to include("plan #{plan.id}")
  end
end
