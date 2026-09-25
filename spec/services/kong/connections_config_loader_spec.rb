require "rails_helper"
require "tempfile"

RSpec.describe Kong::ConnectionsConfigLoader do
  it "upserts a KongConnection for every entry, without ever setting a credential" do
    Tempfile.create([ "connections", ".yml" ]) do |file|
      file.write(<<~YAML)
        - name: dev
          env: dev
          admin_url: http://127.0.0.1:8001
          apply_mode: direct
        - name: prod
          env: prod
          admin_url: https://kong-prod-admin-ro.internal
          apply_mode: pr
          select_tags: [managed-by-kongctl]
          shared_usernames: [kong-admin]
      YAML
      file.flush

      connections = described_class.call(path: file.path)

      expect(connections.map(&:name)).to contain_exactly("default/dev", "default/prod")

      dev = connections.find { |c| c.name == "default/dev" }
      expect(dev.rank).to eq(0)
      expect(dev.color_tag).to eq("green")
      expect(dev.auth_username).to be_nil
      expect(dev.auth_secret).to be_nil

      prod = connections.find { |c| c.name == "default/prod" }
      expect(prod.rank).to eq(3)
      expect(prod.apply_mode).to eq("pr")
      expect(prod.select_tags).to eq([ "managed-by-kongctl" ])
      expect(prod.shared_usernames).to eq([ "kong-admin" ])
    end
  end

  it "ignores a rank in the file: env alone decides it" do
    Tempfile.create([ "connections", ".yml" ]) do |file|
      file.write(<<~YAML)
        - name: prod
          env: prod
          rank: 0
          admin_url: https://kong-prod-admin-ro.internal
      YAML
      file.flush

      expect(described_class.call(path: file.path).first.rank).to eq(3)
    end
  end

  it "only sets allow_insecure_http from the file's own insecure_http key" do
    Tempfile.create([ "connections", ".yml" ]) do |file|
      file.write(<<~YAML)
        - name: dev
          env: dev
          admin_url: http://kong-admin.internal:8000
          insecure_http: true
      YAML
      file.flush

      connections = described_class.call(path: file.path)
      expect(connections.first).to be_valid
      expect(connections.first.allow_insecure_http).to eq(true)
    end
  end

  it "is idempotent -- reloading the same file updates rather than duplicates" do
    Tempfile.create([ "connections", ".yml" ]) do |file|
      file.write("- name: dev\n  env: dev\n  admin_url: http://127.0.0.1:8001\n")
      file.flush

      described_class.call(path: file.path)
      expect { described_class.call(path: file.path) }.not_to change(KongConnection, :count)
    end
  end

  it "returns an empty list when the file doesn't exist" do
    expect(described_class.call(path: "/nonexistent/connections.yml")).to eq([])
  end

  describe "project format" do
    let(:path) { Rails.root.join("spec/fixtures/connections/two_projects.yml") }

    it "creates both projects with their own envs in their own order" do
      described_class.call(path: path)
      expect(Project.find_by!(key: "project-a").project_envs.map(&:name)).to eq(%w[dev sit uat pt ps prod])
      expect(Project.find_by!(key: "project-x").project_envs.map(&:name)).to eq(%w[nonprod pt prod])
    end

    it "marks everything it loads as registry and names connections project/env" do
      described_class.call(path: path)
      expect(KongConnection.pluck(:name)).to include("project-a/ps", "project-x/nonprod")
      expect(ProjectEnv.distinct.pluck(:source)).to eq(%w[registry])
    end

    it "leaves an env without apply_mode unset instead of direct" do
      described_class.call(path: path)
      expect(KongConnection.find_by!(name: "project-x/pt").apply_mode).to be_nil
    end

    it "refuses the whole file when an 'other' env has no rank, naming it" do
      bad = Rails.root.join("tmp/bad_registry.yml")
      File.write(bad, { "projects" => [ { "key" => "p", "name" => "P", "envs" => [ { "name" => "pt", "admin_url" => "http://localhost:1" } ] } ] }.to_yaml)
      expect { described_class.call(path: bad) }.to raise_error(described_class::InvalidRegistry, %r{p/pt.*rank})
      expect(Project.count).to eq(0)
    end

    it "reads network_note per project" do
      described_class.call(path: path)
      expect(Project.find_by!(key: "project-a").network_note).to eq("Reachable from the NONPROD VPN only")
    end

    it "keeps a stored credential when the file is loaded again" do
      described_class.call(path: path)
      KongConnection.find_by!(name: "project-a/dev").update!(credential_mode: "stored", auth_username: "u", auth_secret: "s")
      described_class.call(path: path)
      expect(KongConnection.find_by!(name: "project-a/dev").auth_secret).to eq("s")
    end

    it "follows the file when envs are reordered and an apply_mode changes" do
      described_class.call(path: path)
      moved = Rails.root.join("tmp/moved_registry.yml")
      File.write(moved, { "projects" => [ { "key" => "project-x", "name" => "Project X", "envs" => [
        { "name" => "prod", "apply_mode" => "pr", "admin_url" => "https://kong-x-prod-ro.internal", "git_path" => "prod/kong.yaml" },
        { "name" => "nonprod", "rank" => 1, "apply_mode" => "direct", "admin_url" => "http://localhost:8051" },
        { "name" => "pt", "rank" => 1, "apply_mode" => "direct", "admin_url" => "http://localhost:8061" }
      ] } ] }.to_yaml)
      described_class.call(path: moved)
      expect(Project.find_by!(key: "project-x").project_envs.map(&:name)).to eq(%w[prod nonprod pt])
      expect(KongConnection.find_by!(name: "project-x/pt").apply_mode).to eq("direct")
    end

    it "keeps an env that left the file and says so, instead of deleting it" do
      described_class.call(path: path)
      smaller = Rails.root.join("tmp/smaller_registry.yml")
      File.write(smaller, { "projects" => [ { "key" => "project-x", "name" => "Project X", "envs" => [
        { "name" => "nonprod", "rank" => 1, "apply_mode" => "direct", "admin_url" => "http://localhost:8051" }
      ] } ] }.to_yaml)
      loader = described_class.new(smaller)
      loader.call
      expect(KongConnection.find_by(name: "project-x/pt")).to be_present
      expect(loader.warnings.join("\n")).to include("project-x/pt", "project-x/prod", "project-a/dev")
    end

    it "never puts a secret key from the file on a connection" do
      leaky = Rails.root.join("tmp/leaky_registry.yml")
      File.write(leaky, { "projects" => [ { "key" => "p", "name" => "P", "envs" => [
        { "name" => "dev", "apply_mode" => "direct", "admin_url" => "http://localhost:1", "auth_secret" => "nope", "password" => "nope" }
      ] } ] }.to_yaml)
      described_class.call(path: leaky)
      expect(KongConnection.find_by!(name: "p/dev").auth_secret).to be_nil
    end
  end

  it "still loads the legacy flat list into project default" do
    described_class.call(path: Rails.root.join("spec/fixtures/connections/legacy.yml"))
    expect(KongConnection.pluck(:name)).to include("default/dev-readwrite")
  end
end
