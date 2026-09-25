require "rails_helper"
require Rails.root.join("spec/support/bare_git_repo")

# R8.6: a changeset leaves Kongsole as one gated branch with a PR body. Every
# refusal happens before the push, and leaves git, the changeset and its
# items as they were.
RSpec.describe Kong::ChangesetSubmitter do
  include BareGitRepo

  let(:repo) { bare_git_repo(path: "uat/kong.yaml", select_tags: %w[managed-by-kongctl]) }
  let(:project) { create(:project, git_repo: repo.to_s, git_branch: "main") }
  let(:env) { create(:project_env, project: project, name: "uat", apply_mode: "pr", source: "registry",
    git_path: "uat/kong.yaml", select_tags: %w[managed-by-kongctl]) }
  let(:connection) { create(:kong_connection, project_env: env, access_level: "ro") }
  let(:changeset) { create(:changeset, kong_connection: connection) }

  before do
    allow(Kong::DeckCli).to receive(:validate).and_return(true)
    allow(Kong::DeckCli).to receive(:diff).and_return({ "changes" => { "creating" => [ { "kind" => "service", "name" => "billing" } ], "updating" => [], "deleting" => [] } })
  end

  def add_create_item(changeset, name)
    create(:change_plan, changeset: changeset, kong_connection: changeset.kong_connection, apply_mode: "pr",
      position: changeset.change_plans.maximum(:position).to_i + 1, operation: "create", entity_type: "service",
      provisional_kong_id: SecureRandom.uuid, target_kong_id: nil, before: {},
      after: { "name" => name, "host" => "#{name}.internal", "tags" => %w[managed-by-kongctl] }, diff: { "operation" => "create" })
  end

  def submitter(**overrides)
    described_class.new(changeset: changeset, client: nil, secret: "pw", actor_username: "a", actor_operator: nil, **overrides)
  end

  def branches
    Open3.capture3("git", "--git-dir=#{repo}", "branch", "--list", "kongctl/*").first
  end

  it "pushes one branch with every item, a Changed-by trailer, and records the result" do
    add_create_item(changeset, "billing")
    add_create_item(changeset, "ledger")

    result = described_class.new(changeset: changeset, client: nil, secret: "pw", actor_username: "kong-admin",
      actor_operator: "somchai@example.com").call

    expect(result).to have_attributes(status: "submitted", branch: "kongctl/changeset-#{changeset.id}", submitted_by: "kong-admin")
    log = Open3.capture3("git", "--git-dir=#{repo}", "log", "-1", "--format=%B", "kongctl/changeset-#{changeset.id}").first
    expect(log).to include("Changed-by: somchai@example.com")
    expect(Open3.capture3("git", "--git-dir=#{repo}", "rev-list", "--count", "main..kongctl/changeset-#{changeset.id}").first.strip).to eq("1")
    yaml = Open3.capture3("git", "--git-dir=#{repo}", "show", "kongctl/changeset-#{changeset.id}:uat/kong.yaml").first
    expect(yaml).to include("name: billing", "name: ledger")
    expect { Kong::DeckDocument.verify_input!(yaml) }.not_to raise_error
    expect(changeset.change_plans.reload.map(&:status)).to all(eq("applied"))
    expect(changeset.change_plans.map(&:pr_state)).to all(eq("branch_pushed"))
    expect(AuditEvent.where(change_plan_id: changeset.change_plans.ids).count).to eq(2)
    expect(result.pr_body).to include("billing", "ledger", "Changed-by: somchai@example.com")
    expect(result.commit_sha).to be_present
  end

  it "blocks before pushing when the diff deletes more than the project's threshold" do
    project.update!(delete_threshold: 1)
    allow(Kong::DeckCli).to receive(:diff).and_return({ "changes" => { "creating" => [], "updating" => [],
      "deleting" => [ { "kind" => "service", "name" => "a" }, { "kind" => "service", "name" => "b" } ] } })
    add_create_item(changeset, "billing")

    expect { submitter.call }.to raise_error(Kong::ChangeGuardrails::Violation, /over the threshold of 1/)
    expect(branches).to be_empty
    expect(changeset.reload).to be_open
  end

  it "blocks an item on the admin path, even one that got in before the planner refused them" do
    admin_id = SecureRandom.uuid
    connection.update!(admin_path_fingerprint: { "service_id" => admin_id, "route_ids" => [], "plugin_ids" => [], "consumer_ids" => [] })
    create(:change_plan, changeset: changeset, kong_connection: connection, apply_mode: "pr", position: 1,
      operation: "update", target_kong_id: admin_id)
    expect { submitter.call }.to raise_error(Kong::ChangeGuardrails::Violation, /admin path/)
    expect(branches).to be_empty
  end

  it "leaves everything as it was when decK rejects the file" do
    allow(Kong::DeckCli).to receive(:validate).and_raise(Kong::DeckCli::Error, "deck file validate failed: bad")
    add_create_item(changeset, "billing")
    expect { submitter.call }.to raise_error(Kong::DeckCli::Error)
    expect(changeset.reload).to have_attributes(status: "open", failure_reason: include("deck file validate failed"))
    expect(changeset.items.map(&:status)).to all(eq("pending"))
    expect(branches).to be_empty
    status, = Open3.capture3("git", "status", "--porcelain", chdir: Kong::GitClient.new(connection: connection).working_dir.to_s)
    expect(status).to be_empty
  end

  it "requires acknowledging drift before submitting over it" do
    changeset.update!(base_git_sha: "0" * 40)
    add_create_item(changeset, "billing")
    expect { submitter.call }.to raise_error(Kong::ChangeGuardrails::Violation, /changed since this changeset began/)
    expect(submitter(acknowledge_drift: true).call.status).to eq("submitted")
  end

  it "refuses an empty changeset, and one already submitted" do
    expect { submitter.call }.to raise_error(Kong::ChangeGuardrails::Violation, /no items/)
    changeset.update!(status: "submitted")
    expect { submitter.call }.to raise_error(Kong::ChangeGuardrails::Violation, /submitted, not open/)
  end

  it "scrubs a token in the repo URL out of the stored failure reason" do
    add_create_item(changeset, "billing")
    allow_any_instance_of(Kong::GitClient).to receive(:push!)
      .and_raise(Kong::GitClient::Error, "git push failed: fatal: https://kongctl:s3cr3t-token@git.example/team/repo.git rejected")
    expect { submitter.call }.to raise_error(Kong::GitClient::Error)
    expect(changeset.reload.failure_reason).not_to include("s3cr3t-token")
    expect(changeset.items.map(&:status)).to all(eq("pending"))
  end

  it "makes no write call to Kong" do
    add_create_item(changeset, "billing")
    submitter.call
    expect(a_request(:any, //).with { |req| %i[post put patch delete].include?(req.method) }).not_to have_been_made
  end
end
