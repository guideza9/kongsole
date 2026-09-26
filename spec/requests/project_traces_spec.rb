require "rails_helper"

RSpec.describe "Project trace", type: :request do
  let(:project) { create(:project, key: "project-a") }
  let(:env) { create(:project_env, project: project, name: "dev", position: 1) }
  let(:connection) { create(:kong_connection, project_env: env) }

  before do
    service = create(:kong_entity, kong_connection: connection, entity_type: "service", name: "billing",
      data: { "protocol" => "http", "host" => "billing.internal", "port" => 8080, "path" => "/api" })
    create(:kong_entity, kong_connection: connection, entity_type: "route", name: "billing-v1", parent_type: "service",
      parent_kong_id: service.kong_id, data: { "protocols" => %w[http https], "paths" => %w[/billing/v1], "hosts" => [],
        "methods" => [], "strip_path" => true, "path_handling" => "v0" })
  end

  it "traces a request without logging in and without calling Kong" do
    get project_trace_path(project.key), params: { env: "dev", host: "api.example.com", path: "/billing/v1/invoices/42?status=paid", method: "GET" }

    expect(response).to have_http_status(:ok)
    expect(response.body).to include("billing-v1", "billing", "http://billing.internal:8080/api/invoices/42?status=paid")
    expect(a_request(:any, //)).not_to have_been_made
  end

  it "says Kong would answer 404 when no route matches" do
    get project_trace_path(project.key), params: { env: "dev", host: "api.example.com", path: "/nothing", method: "GET" }
    expect(response.body).to include("Kong would answer 404")
  end

  it "shows the empty form before anything is traced" do
    get project_trace_path(project.key)
    expect(response).to have_http_status(:ok)
    expect(response.body).to include('name="path"')
  end

  it "reports field errors for a path without a leading slash" do
    get project_trace_path(project.key), params: { env: "dev", host: "x", path: "billing", method: "GET" }
    expect(response).to have_http_status(:unprocessable_entity)
  end

  it "404s for an unknown project key" do
    get project_trace_path("nope")
    expect(response).to have_http_status(:not_found)
  end
end
