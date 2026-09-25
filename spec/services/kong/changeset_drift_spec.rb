require "rails_helper"
require Rails.root.join("spec/support/bare_git_repo")

# R8.5: before a changeset is submitted, say whether git or Kong moved since
# it began -- without writing to either.
RSpec.describe Kong::ChangesetDrift do
  include BareGitRepo

  let(:repo) { bare_git_repo(path: "uat/kong.yaml", select_tags: %w[t]) }
  let(:connection) { pr_connection_for(repo, path: "uat/kong.yaml", select_tags: %w[t]) }

  it "counts commits pushed to the base branch since the changeset started" do
    changeset = create(:changeset, kong_connection: connection, base_git_sha: head_sha(repo))
    push_empty_commit(repo)
    git = Kong::GitClient.new(connection: connection).pull!
    report = described_class.check(changeset: changeset, git: git, client: nil)
    expect(report.commits_behind).to eq(1)
    expect(report.git_moved?).to be(true)
    expect(report).to be_any
  end

  it "reports nothing when neither moved" do
    changeset = create(:changeset, kong_connection: connection, base_git_sha: head_sha(repo))
    git = Kong::GitClient.new(connection: connection).pull!
    report = described_class.check(changeset: changeset, git: git, client: nil)
    expect(report.commits_behind).to eq(0)
    expect(report.git_moved?).to be(false)
    expect(report).not_to be_any
  end

  it "treats a base it cannot find as unknown, which still asks for a look" do
    changeset = create(:changeset, kong_connection: connection, base_git_sha: "0" * 40)
    git = Kong::GitClient.new(connection: connection).pull!
    report = described_class.check(changeset: changeset, git: git, client: nil)
    expect(report.commits_behind).to be_nil
    expect(report.git_moved?).to be_nil
    expect(report).to be_any
  end

  it "lists update/delete items whose entity changed in Kong since they were proposed" do
    connection.update!(admin_url: "https://kong.test")
    changeset = create(:changeset, kong_connection: connection, base_git_sha: head_sha(repo))
    kong_id = SecureRandom.uuid
    plan = create(:change_plan, changeset: changeset, kong_connection: connection, position: 1, apply_mode: "pr",
      operation: "update", entity_type: "service", target_kong_id: kong_id, base_updated_at: Time.zone.at(100),
      before: { "id" => kong_id, "name" => "billing" }, after: { "name" => "billing", "tags" => %w[t] })
    unchanged_id = SecureRandom.uuid
    create(:change_plan, changeset: changeset, kong_connection: connection, position: 2, apply_mode: "pr",
      operation: "delete", entity_type: "service", target_kong_id: unchanged_id, base_updated_at: Time.zone.at(100),
      before: { "id" => unchanged_id, "name" => "ledger" }, after: {})
    stub_request(:get, "https://kong.test/services/#{kong_id}")
      .to_return(status: 200, body: { id: kong_id, name: "billing", updated_at: 200 }.to_json)
    stub_request(:get, "https://kong.test/services/#{unchanged_id}")
      .to_return(status: 200, body: { id: unchanged_id, name: "ledger", updated_at: 100 }.to_json)
    client = Kong::Client.new(connection: connection, secret: "pw")
    git = Kong::GitClient.new(connection: connection).pull!

    report = described_class.check(changeset: changeset, git: git, client: client)

    expect(report.kong_changed).to eq([ { plan_id: plan.id, label: "service billing" } ])
    expect(a_request(:any, /kong\.test/).with { |req| req.method != :get }).not_to have_been_made
  end

  it "counts an entity someone deleted from Kong as changed" do
    connection.update!(admin_url: "https://kong.test")
    changeset = create(:changeset, kong_connection: connection, base_git_sha: head_sha(repo))
    kong_id = SecureRandom.uuid
    plan = create(:change_plan, changeset: changeset, kong_connection: connection, position: 1, apply_mode: "pr",
      operation: "update", entity_type: "service", target_kong_id: kong_id, base_updated_at: Time.zone.at(100),
      before: { "id" => kong_id, "name" => "billing" }, after: { "name" => "billing" })
    stub_request(:get, "https://kong.test/services/#{kong_id}").to_return(status: 404, body: { message: "Not found" }.to_json)

    report = described_class.check(changeset: changeset, git: Kong::GitClient.new(connection: connection).pull!,
      client: Kong::Client.new(connection: connection, secret: "pw"))
    expect(report.kong_changed).to eq([ { plan_id: plan.id, label: "service billing" } ])
  end
end
