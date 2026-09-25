require "rails_helper"

RSpec.describe Kong::LegacyProjectBackfill do
  # Legacy rows predate project envs: saved without validation, as the
  # migration finds them. The NOT NULL comes after the backfill in the
  # migration, so it is lifted here (DDL rolls back with the example).
  before { ActiveRecord::Base.connection.execute("ALTER TABLE kong_connections ALTER COLUMN project_env_id DROP NOT NULL") }

  def legacy(attrs)
    KongConnection.new(attrs).tap { |c| c.save!(validate: false) }
  end

  it "gives every legacy connection its own env in project 'default', keeping its credential" do
    rw = legacy(name: "dev-readwrite", env: "dev", rank: 0, admin_url: "http://localhost:8001",
      color_tag: "green", apply_mode: "direct", credential_mode: "stored", auth_username: "jakkapat", auth_secret: "pw")
    ro = legacy(name: "dev-readonly", env: "dev", rank: 0, admin_url: "http://localhost:8001",
      color_tag: "green", apply_mode: "direct")

    described_class.call

    expect(rw.reload.project_env.qualified_name).to eq("default/dev-readwrite")
    expect(ro.reload.project_env.qualified_name).to eq("default/dev-readonly")
    expect(rw.project_env.rank).to eq(0)
    expect(rw.auth_secret).to eq("pw")
  end

  it "renames the connection project/env so a token can name it" do
    c = legacy(name: "sit", env: "sit", rank: 1, admin_url: "http://localhost:8011", color_tag: "yellow", apply_mode: "direct")
    described_class.call
    expect(c.reload.name).to eq("default/sit")
  end

  it "is idempotent" do
    legacy(name: "uat", env: "uat", rank: 2, admin_url: "http://localhost:8001", color_tag: "orange", apply_mode: "pr")
    2.times { described_class.call }
    expect(ProjectEnv.count).to eq(1)
  end

  it "reattaches rows to their own envs after a rollback and a second migrate, without duplicating envs" do
    c = legacy(name: "sit", env: "sit", rank: 1, admin_url: "http://localhost:8011", color_tag: "yellow", apply_mode: "direct")
    described_class.call
    env = c.reload.project_env
    c.update_columns(project_env_id: nil) # what the rollback leaves: renamed rows, envs still there

    described_class.call

    expect(ProjectEnv.count).to eq(1)
    expect(c.reload).to have_attributes(project_env_id: env.id, name: "default/sit")
  end

  it "keeps the name after a full rollback dropped projects, instead of prefixing it twice" do
    c = legacy(name: "default/dev-readwrite", env: "dev", rank: 0, admin_url: "http://localhost:8001", color_tag: "green", apply_mode: "direct")
    described_class.call
    expect(c.reload.name).to eq("default/dev-readwrite")
  end

  it "keeps a PR env's git settings, marking it as coming from connections.yml" do
    legacy(name: "uat", env: "uat", rank: 2, admin_url: "http://localhost:8001", color_tag: "orange", apply_mode: "pr",
      git_repo: "/tmp/uat.git", git_branch: "main", git_path: "uat/kong.yaml", select_tags: [ "managed-by-kongctl" ])
    described_class.call
    env = ProjectEnv.sole
    expect(env).to have_attributes(source: "registry", apply_mode: "pr", git_path: "uat/kong.yaml", select_tags: [ "managed-by-kongctl" ])
    expect(env.project).to have_attributes(key: "default", git_repo: "/tmp/uat.git", git_branch: "main")
  end

  it "refuses to merge PR connections that push to different repos into one project" do
    legacy(name: "uat", env: "uat", rank: 2, admin_url: "http://localhost:8001", color_tag: "orange", apply_mode: "pr", git_repo: "/tmp/a.git")
    legacy(name: "prod", env: "prod", rank: 3, admin_url: "http://localhost:8001", color_tag: "red", apply_mode: "pr", git_repo: "/tmp/b.git")
    expect { described_class.call }.to raise_error(described_class::ConflictingRepos, %r{/tmp/a\.git.*/tmp/b\.git})
  end
end
