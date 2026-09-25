require "rails_helper"
require Rails.root.join("spec/support/bare_git_repo")

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
  # R8.5: where the changeset began, so a submit can tell whether git moved.
  describe "the base it began from" do
    include BareGitRepo

    it "records the config repo's head when it opens" do
      repo = bare_git_repo(path: "uat/kong.yaml", select_tags: %w[t])
      pr = pr_connection_for(repo, path: "uat/kong.yaml", select_tags: %w[t])
      changeset = described_class.open_for!(connection: pr, actor_username: "a", actor_operator: nil)
      expect(changeset.base_git_sha).to eq(head_sha(repo))
    end

    it "opens anyway, with no base, when the repo cannot be read" do
      pr = create(:kong_connection, project_env: create(:project_env, apply_mode: "pr", source: "registry",
        project: create(:project, git_repo: "/no/such/repo.git")))
      expect(described_class.open_for!(connection: pr, actor_username: "a", actor_operator: nil).base_git_sha).to be_nil
    end
  end
end
