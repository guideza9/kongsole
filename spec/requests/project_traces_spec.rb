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

  it "shows the four stops in order, each explaining only its own settings" do
    get project_trace_path(project.key), params: { env: "dev", host: "api.example.com", path: "/billing/v1/invoices/42?status=paid", method: "GET" }
    page = Nokogiri::HTML(response.body)

    stops = page.css("ol.trace-stops > li")
    expect(stops.map { _1["data-stop"] }).to eq(%w[request route plugins service])
    expect(stops[1].text).to include("strip_path", "/billing/v1")
    expect(stops[3].text.squish).to include("http://billing.internal:8080/api/invoices/42?status=paid")
    expect(stops[3].text).not_to include("strip_path")
    expect(page.text).to include("traditional_compatible")
  end

  it "names enabled plugins that may stop the request, and leaves disabled ones out of the note" do
    create(:kong_entity, kong_connection: connection, entity_type: "plugin", name: "key-auth", enabled: true, data: { "name" => "key-auth" })
    create(:kong_entity, kong_connection: connection, entity_type: "plugin", name: "acl", enabled: false, data: { "name" => "acl" })

    get project_trace_path(project.key), params: { env: "dev", host: "api.example.com", path: "/billing/v1/x", method: "GET" }
    note = Nokogiri::HTML(response.body).at_css(".trace-plugin-note")

    expect(note.text.squish).to include("key-auth", "401", "it does not run them")
    expect(note.text).not_to include("acl")
  end

  it "says the request is not forwarded when request-termination answers" do
    create(:kong_entity, kong_connection: connection, entity_type: "plugin", name: "request-termination", enabled: true,
      data: { "name" => "request-termination", "config" => { "status_code" => 503, "message" => "Billing is under maintenance" } })
    get project_trace_path(project.key), params: { env: "dev", host: "api.example.com", path: "/billing/v1/x", method: "GET" }
    expect(Nokogiri::HTML(response.body).text.squish).to include("Not forwarded", "503", "Billing is under maintenance")
  end
end
