require "rails_helper"

RSpec.describe KongConnection, type: :model do
  it "is valid with a minimal set of attributes" do
    expect(build(:kong_connection)).to be_valid
  end

  it "requires env to be one of the four ranked environments" do
    connection = build(:kong_connection, env: "staging")
    expect(connection).not_to be_valid
    expect(connection.errors[:env]).to be_present
  end

  it "requires a unique name" do
    create(:kong_connection, name: "dev")
    expect(build(:kong_connection, name: "dev")).not_to be_valid
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
    connection = create(:kong_connection, env: "prod", rank: 3, color_tag: nil)
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
end
