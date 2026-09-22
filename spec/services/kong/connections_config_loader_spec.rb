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

      expect(connections.map(&:name)).to contain_exactly("dev", "prod")

      dev = connections.find { |c| c.name == "dev" }
      expect(dev.rank).to eq(0)
      expect(dev.color_tag).to eq("green")
      expect(dev.auth_username).to be_nil
      expect(dev.auth_secret).to be_nil

      prod = connections.find { |c| c.name == "prod" }
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
end
