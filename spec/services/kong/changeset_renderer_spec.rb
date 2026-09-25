require "rails_helper"
require Rails.root.join("spec/support/bare_git_repo")

# R8.4: a whole changeset rendered from the latest git, previewed without
# committing or pushing.
RSpec.describe Kong::ChangesetRenderer do
  include BareGitRepo

  let(:repo) { bare_git_repo(path: "uat/kong.yaml", select_tags: %w[managed-by-kongctl]) }
  let(:project) { create(:project, git_repo: repo.to_s, git_branch: "main") }
  let(:env) { create(:project_env, project: project, name: "uat", apply_mode: "pr", source: "registry",
    git_path: "uat/kong.yaml", select_tags: %w[managed-by-kongctl]) }
  let(:connection) { create(:kong_connection, project_env: env) }
  let(:changeset) { create(:changeset, kong_connection: connection) }

  before do
    allow(Kong::DeckCli).to receive(:validate).and_return(true)
    allow(Kong::DeckCli).to receive(:diff).and_return({ "changes" => { "creating" => [ { "kind" => "service", "name" => "billing" } ], "updating" => [], "deleting" => [] } })
  end

  def create_item(name, position: 1)
    create(:change_plan, changeset: changeset, kong_connection: connection, position: position, operation: "create",
      entity_type: "service", apply_mode: "pr", provisional_kong_id: SecureRandom.uuid, target_kong_id: nil,
      after: { "name" => name, "host" => "#{name}.internal", "tags" => %w[managed-by-kongctl] })
  end

  def branches(repo)
    Open3.capture3("git", "--git-dir=#{repo}", "branch", "--list", "kongctl/*").first
  end

  it "previews the whole changeset as one YAML diff without committing or pushing" do
    create_item("billing")

    preview = described_class.new(changeset: changeset, secret: "pw").preview

    expect(preview.error).to be_nil
    expect(preview.yaml_diff).to include("+  - name: billing")
    expect(preview.gate).to be_passed
    expect(branches(repo)).to be_empty
    expect(Open3.capture3("git", "--git-dir=#{repo}", "log", "--oneline", "main").first.lines.size).to eq(1)
  end

  it "renders every item, in order, into the one file" do
    create_item("billing", position: 1)
    create_item("ledger", position: 2)
    preview = described_class.new(changeset: changeset, secret: "pw").preview
    expect(preview.yaml_diff.index("name: billing")).to be < preview.yaml_diff.index("name: ledger")
  end

  it "hands decK the env's extra files alongside the rendered one" do
    env.update!(deck_extra_paths: %w[uat/base.yaml])
    create_item("billing")
    described_class.new(changeset: changeset, secret: "pw").preview
    expect(Kong::DeckCli).to have_received(:validate).with(anything, extra_paths: [ a_string_ending_with("uat/base.yaml") ])
    expect(Kong::DeckCli).to have_received(:diff).with(anything, hash_including(extra_paths: [ a_string_ending_with("uat/base.yaml") ]))
  end

  it "reports an unrenderable item as the preview error, leaving the working copy clean" do
    create(:change_plan, changeset: changeset, kong_connection: connection, position: 1, operation: "update",
      entity_type: "service", apply_mode: "pr", before: { "name" => "ghost" }, after: { "name" => "ghost", "tags" => [] })
    preview = described_class.new(changeset: changeset, secret: "pw").preview
    expect(preview.error).to match(/no service with name ghost in this YAML/)
    status, = Open3.capture3("git", "status", "--porcelain", chdir: Kong::GitClient.new(connection: connection).working_dir.to_s)
    expect(status).to be_empty
  end

  it "refuses a connection with no select_tags" do
    env.update!(select_tags: [])
    connection.reload.save!
    create_item("billing")
    preview = described_class.new(changeset: changeset.reload, secret: "pw").preview
    expect(preview.error).to match(/no select_tags/)
  end

  it "explains a config repo this machine cannot reach, with the project's network note" do
    project.update!(network_note: "Reachable from the NONPROD VPN only")
    allow_any_instance_of(Kong::GitClient).to receive(:pull!)
      .and_raise(Kong::GitClient::Unreachable.new("git fetch failed", kind: :dns))
    preview = described_class.new(changeset: changeset, secret: "pw").preview
    expect(preview.explanation.key).to eq("network_dns_failed")
    expect(preview.explanation.next_step).to include("NONPROD VPN")
  end
  it "says in the preview whether git moved since the changeset began (R8.5)" do
    changeset.update!(base_git_sha: head_sha(repo))
    create_item("billing")
    push_empty_commit(repo)
    preview = described_class.new(changeset: changeset, secret: "pw").preview
    expect(preview.drift.commits_behind).to eq(1)
  end
  # Found in R8.10: a git failure that is not about the network must not be
  # explained as "could not reach this connection".
  it "gives a git failure that is not a network one no network explanation" do
    allow_any_instance_of(Kong::GitClient).to receive(:pull!)
      .and_raise(Kong::GitClient::Error, "git clone --branch main /repo.git /cache failed: fatal: Remote branch main not found")
    preview = described_class.new(changeset: changeset, secret: "pw").preview
    expect(preview.error).to include("Remote branch main not found")
    expect(preview.explanation).to be_nil
  end
end
