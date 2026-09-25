require "rails_helper"

RSpec.describe RouteForm do
  let(:valid) { { name: "billing-v1", protocols: %w[http https], methods: %w[GET POST], hosts: "api.example.com\n",
                  paths: "/billing\n~/billing/v[0-9]+$", strip_path: "1", preserve_host: "0", tags: "" } }

  it "builds Kong's route body under its service" do
    attrs = described_class.new(valid).to_attributes(select_tags: %w[managed-by-kongctl], service_kong_id: "s-1")
    expect(attrs).to include("name" => "billing-v1", "protocols" => %w[http https], "methods" => %w[GET POST],
      "hosts" => %w[api.example.com], "paths" => [ "/billing", "~/billing/v[0-9]+$" ], "strip_path" => true,
      "preserve_host" => false, "tags" => %w[managed-by-kongctl], "service" => { "id" => "s-1" })
  end

  it "requires a name, because decK cannot place a route without one" do
    expect(described_class.new(valid.merge(name: ""))).not_to be_valid
  end

  it "requires at least one of methods, hosts or paths" do
    form = described_class.new(valid.merge(methods: [], hosts: "", paths: ""))
    expect(form).not_to be_valid
    expect(form.errors[:base].join).to match(/method, host or path/)
  end

  it "rejects a path that is neither /… nor ~regex" do
    expect(described_class.new(valid.merge(paths: "billing"))).not_to be_valid
  end

  it "rejects an invalid regex path with the regex error, not a 500" do
    form = described_class.new(valid.merge(paths: "~/billing/("))
    expect(form).not_to be_valid
    expect(form.errors[:paths].join).to match(/regex/)
  end

  it "rejects a host with a wildcard in the middle" do
    expect(described_class.new(valid.merge(hosts: "api.*.example.com"))).not_to be_valid
  end

  it "omits empty hosts/methods instead of sending empty arrays" do
    attrs = described_class.new(valid.merge(hosts: "", methods: [])).to_attributes(select_tags: [], service_kong_id: "s")
    expect(attrs.keys).not_to include("hosts", "methods")
  end
end
