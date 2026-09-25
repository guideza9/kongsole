require "rails_helper"

RSpec.describe ServiceForm do
  let(:valid) { { name: "billing", protocol: "http", host: "billing.internal", port: "8080", path: "/api",
                  retries: "5", connect_timeout: "60000", read_timeout: "60000", write_timeout: "60000", enabled: "1", tags: "team-a, payments" } }

  it "builds Kong's service body with typed values" do
    attrs = described_class.new(valid).to_attributes(select_tags: [])
    expect(attrs).to include("name" => "billing", "protocol" => "http", "host" => "billing.internal", "port" => 8080,
      "path" => "/api", "retries" => 5, "enabled" => true, "tags" => %w[team-a payments])
  end

  it "adds the connection's select_tags without duplicates or blanks" do
    attrs = described_class.new(valid.merge(tags: "managed-by-kongctl, , team-a")).to_attributes(select_tags: %w[managed-by-kongctl])
    expect(attrs["tags"]).to eq(%w[managed-by-kongctl team-a])
  end

  it "defaults the port from the protocol" do
    expect(described_class.new(valid.merge(protocol: "https", port: "")).to_attributes(select_tags: [])["port"]).to eq(443)
  end

  {
    name: [ "bad name", "must use letters, digits, . _ ~ -" ],
    host: [ "", "can't be blank" ],
    port: [ "70000", "must be between 1 and 65535" ],
    path: [ "api", "must start with /" ],
    read_timeout: [ "0", "must be between 1 and 2147483646" ],
    protocol: [ "ftp", "is not included in the list" ]
  }.each do |field, (value, message)|
    it "rejects #{field}=#{value.inspect}" do
      form = described_class.new(valid.merge(field => value))
      expect(form).not_to be_valid
      expect(form.errors[field].join).to include(message)
    end
  end

  it "omits empty optional fields instead of sending nulls (decK rejects null)" do
    attrs = described_class.new(valid.merge(path: "")).to_attributes(select_tags: [])
    expect(attrs).not_to have_key("path")
  end

  # Final review #1: Kong's service schema refuses these at apply (direct) or in
  # CI (PR); the form says so before anything is proposed.
  it "refuses a path on a gRPC service, which Kong requires to have none" do
    form = described_class.new(valid.merge(protocol: "grpc", path: "/api"))
    expect(form).not_to be_valid
    expect(form.errors[:path].join).to match(/grpc/)
  end

  [ "http://billing.internal", "billing.internal/api", "billing internal", "billing.internal:8080" ].each do |host|
    it "refuses host #{host.inspect}, which is not a bare host name or IP" do
      form = described_class.new(valid.merge(host: host))
      expect(form).not_to be_valid
      expect(form.errors[:host]).to be_present
    end
  end

  it "accepts an IP address or a Kong upstream name as the host" do
    expect(described_class.new(valid.merge(host: "10.0.0.12"))).to be_valid
    expect(described_class.new(valid.merge(host: "payments_upstream"))).to be_valid
  end

  it "refuses a tag with a slash, which Kong rejects" do
    form = described_class.new(valid.merge(tags: "team/a"))
    expect(form).not_to be_valid
    expect(form.errors[:tags].join).to include("team/a")
  end
end
