require "rails_helper"

RSpec.describe TraceForm do
  let(:project) { create(:project, key: "project-a") }
  let(:env) { create(:project_env, project: project, name: "dev") }
  let!(:connection) { create(:kong_connection, project_env: env) }
  let!(:synced) { create(:kong_entity, kong_connection: connection) }

  def form(**attrs)
    described_class.new(project: project, env: "dev", http_method: "GET", host: "api.example.com", path: "/b", **attrs)
  end

  def errors_of(traced)
    traced.tap(&:valid?).errors.attribute_names
  end

  it "splits the query off the path (Review Focus 5)" do
    traced = form(path: "/billing/v1/invoices/42?status=paid")
    expect([ traced.path_only, traced.query ]).to eq([ "/billing/v1/invoices/42", "status=paid" ])
  end

  it "needs a path that starts with a slash, a known method, a host and an env of this project" do
    expect(errors_of(form)).to be_empty
    expect(errors_of(form(path: "billing"))).to include(:path)
    expect(errors_of(form(http_method: "BREW"))).to include(:http_method)
    expect(errors_of(form(host: ""))).to include(:host)
    expect(errors_of(form(env: "nope"))).to include(:env)
    expect(errors_of(form(path: "/#{'a' * 2048}"))).to include(:path)
  end

  it "refuses an env this machine has never synced, instead of tracing an empty read-model (final review)" do
    uat = create(:project_env, project: project, name: "uat")
    create(:kong_connection, project_env: uat)
    expect(errors_of(form(env: "uat"))).to include(:env)
  end

  it "finds the env's connection" do
    expect(form.connection).to eq(connection)
  end
end
