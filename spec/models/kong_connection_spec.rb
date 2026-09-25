require "rails_helper"

RSpec.describe KongConnection, type: :model do
  it "is valid with a minimal set of attributes" do
    expect(build(:kong_connection)).to be_valid
  end

  it "requires an env to belong to" do
    connection = build(:kong_connection)
    connection.project_env = nil
    expect(connection).not_to be_valid
    expect(connection.errors[:project_env]).to be_present
  end

  # R1: rank lives on the env (ProjectEnv forces dev/sit/uat/prod ranks); the
  # connection only ever carries a copy, so a prod connection still cannot be
  # saved with a quiet rank.
  describe "rank" do
    it "is taken from its env, so a prod connection can never be saved with a quiet rank" do
      connection = create(:kong_connection, env: "prod", rank: 0)

      expect(connection.rank).to eq(3)
      expect(connection).to be_protected_env
    end

    it "follows the env when the env changes" do
      connection = create(:kong_connection, env: "dev")

      connection.project_env.update!(name: "prod")
      connection.save!

      expect(connection.reload.rank).to eq(3)
    end

    it "follows ProjectEnv::KNOWN_RANKS for every known env name" do
      ProjectEnv::KNOWN_RANKS.each do |env, rank|
        expect(create(:kong_connection, env: env).rank).to eq(rank)
      end
    end
  end

  it "takes env, rank, apply_mode and its name from its env, overriding whatever was assigned" do
    env = create(:project_env, name: "ps", rank: 3, apply_mode: "direct", project: create(:project, key: "project-x"))
    connection = create(:kong_connection, project_env: env, rank: 0, apply_mode: "pr", env: "dev")
    expect(connection).to have_attributes(env: "ps", rank: 3, apply_mode: "direct", name: "project-x/ps")
    expect(connection.protected_env?).to be(true)
  end

  it "allows one connection per env" do
    env = create(:project_env)
    create(:kong_connection, project_env: env)
    expect(build(:kong_connection, project_env: env)).not_to be_valid
  end

  it "names itself project/env" do
    connection = create(:kong_connection, project_env: create(:project_env, name: "sit", project: create(:project, key: "project-a")))
    expect(connection.name).to eq("project-a/sit")
    expect(connection.qualified_name).to eq("project-a/sit")
  end

  it "rejects a non-localhost admin_url that isn't https" do
    connection = build(:kong_connection, admin_url: "http://kong-admin.example.com")
    expect(connection).not_to be_valid
    expect(connection.errors[:admin_url].join).to match(/https/)
  end

  it "allows http:// for localhost" do
    connection = build(:kong_connection, admin_url: "http://127.0.0.1:8001")
    expect(connection).to be_valid
  end

  it "allows https:// for a remote host" do
    connection = build(:kong_connection, admin_url: "https://kong-admin.example.com")
    expect(connection).to be_valid
  end

  it "allows a non-localhost http:// admin_url only when allow_insecure_http is set" do
    connection = build(:kong_connection, admin_url: "http://kong-admin.example.com", allow_insecure_http: true)
    expect(connection).to be_valid
  end

  it "defaults the color tag from env when none is given" do
    connection = create(:kong_connection, env: "prod", color_tag: nil)
    expect(connection.color_tag).to eq("red")
  end

  it "transparently encrypts auth_secret at rest" do
    connection = create(:kong_connection, credential_mode: "stored", auth_secret: "s3cr3t")

    raw = ActiveRecord::Base.connection.select_value(
      "SELECT auth_secret FROM kong_connections WHERE id = #{connection.id}"
    )

    expect(raw).not_to include("s3cr3t")
    expect(connection.reload.auth_secret).to eq("s3cr3t")
  end

  it "never leaks auth_secret through inspect" do
    connection = build(:kong_connection, credential_mode: "stored", auth_secret: "s3cr3t")
    expect(connection.inspect).not_to include("s3cr3t")
  end

  describe "#admin_path?" do
    it "delegates to Kong::AdminPathGuard.admin_path?" do
      connection = build(:kong_connection, admin_path_fingerprint: { "service_id" => "abc" })
      expect(connection.admin_path?("abc")).to eq(true)
      expect(connection.admin_path?("xyz")).to eq(false)
    end
  end

  describe "#select_tags_raw" do
    it "round-trips a comma-separated list into the array column" do
      connection = build(:kong_connection)
      connection.select_tags_raw = "a, b ,c"
      expect(connection.select_tags).to eq(%w[a b c])
      expect(connection.select_tags_raw).to eq("a,b,c")
    end
  end

  describe "#branch_url" do
    it "substitutes the branch into the host's own URL shape" do
      connection = build(:kong_connection, git_web_url: "https://github.com/acme/kong-config/tree/{branch}")

      expect(connection.branch_url("kongctl/42")).to eq("https://github.com/acme/kong-config/tree/kongctl/42")
    end

    it "works just as well for a host that carries the branch in a query string" do
      connection = build(:kong_connection, git_web_url: "https://dev.azure.com/acme/kong/_git/config?version=GB{branch}")

      expect(connection.branch_url("kongctl/42")).to eq("https://dev.azure.com/acme/kong/_git/config?version=GBkongctl/42")
    end

    it "escapes a branch segment without eating the separator the URL needs" do
      connection = build(:kong_connection, git_web_url: "https://example.test/tree/{branch}")

      expect(connection.branch_url("kongctl/a b")).to eq("https://example.test/tree/kongctl/a%20b")
    end

    it "is nil with no web host configured -- a local bare repo has nothing to link to" do
      expect(build(:kong_connection, git_web_url: nil).branch_url("kongctl/42")).to be_nil
    end

    it "is nil for a template missing the placeholder, rather than linking at the repo root" do
      connection = build(:kong_connection, git_web_url: "https://github.com/acme/kong-config")

      expect(connection.branch_url("kongctl/42")).to be_nil
    end

    it "is nil for a scheme-less template, which would navigate inside Kongsole instead" do
      connection = build(:kong_connection, git_web_url: "github.com/acme/kong-config/tree/{branch}")

      expect(connection.branch_url("kongctl/42")).to be_nil
    end

    it "is nil for a scheme that has no business in a link this page draws" do
      connection = build(:kong_connection, git_web_url: "javascript:alert(1)/{branch}")

      expect(connection.branch_url("kongctl/42")).to be_nil
    end

    it "refuses to save a template that is not an http(s) URL naming the branch" do
      expect(build(:kong_connection, git_web_url: "javascript:alert(1)/{branch}")).not_to be_valid
      expect(build(:kong_connection, git_web_url: "https://github.com/acme/kong-config")).not_to be_valid
      expect(build(:kong_connection, git_web_url: "https://github.com/acme/c/tree/{branch}")).to be_valid
      expect(build(:kong_connection, git_web_url: nil)).to be_valid
    end
  end

  # R1.13: the one answer to "can this session write?" -- the same rule
  # Kong::ChangeGuardrails.check_write_access! enforces, so the UI can hide
  # what the server would refuse.
  describe "#write_block_reason" do
    def connection_for(apply_mode:, access_level:)
      create(:kong_connection, apply_mode: apply_mode, access_level: access_level)
    end

    it "blocks an env whose apply mode is not set, whatever the credential" do
      expect(connection_for(apply_mode: nil, access_level: "rw").write_block_reason).to eq(:apply_mode_unset)
    end

    it "blocks a direct env whose credential cannot write" do
      expect(connection_for(apply_mode: "direct", access_level: "ro").write_block_reason).to eq(:read_only)
    end

    it "blocks a direct env whose credential has not been probed yet" do
      expect(connection_for(apply_mode: "direct", access_level: nil).write_block_reason).to eq(:read_only)
    end

    it "lets a direct env with a read-write credential write" do
      expect(connection_for(apply_mode: "direct", access_level: "rw").write_block_reason).to be_nil
    end

    it "lets a PR env write with a read-only credential, since it writes to git, not Kong" do
      expect(connection_for(apply_mode: "pr", access_level: "ro").write_block_reason).to be_nil
    end
  end
end
