# spec/requests/routes_spec.rb
require "rails_helper"

# The login access probe (a PATCH the router answers 404) is the sign-in, not
# a write; every other non-GET to Kong fails these examples.
RSpec.describe "Create route", type: :request do
  include SignInHelper

  let(:route_params) { { route_form: { name: "billing-v1", protocols: %w[http https], paths: "/billing", methods: %w[GET] } } }

  context "direct mode" do
    let(:connection) { create(:kong_connection, admin_url: "https://kong.test", project_env: create(:project_env, apply_mode: "direct")) }
    let!(:service) { create(:kong_entity, kong_connection: connection, entity_type: "service", name: "billing") }

    before do
      sign_in_to(connection, access: :rw)
      stub_request(:post, "https://kong.test/schemas/routes/validate").to_return(status: 200, body: "{}")
    end

    it "proposes a route under the service it was opened from" do
      post routes_path, params: route_params.merge(service_id: service.kong_id)
      plan = ChangePlan.last
      expect(response).to redirect_to(change_plan_path(plan))
      expect(plan.after).to include("name" => "billing-v1", "paths" => %w[/billing], "service" => { "id" => service.kong_id })
    end

    it "opens the review of a route create, overlapping routes and all" do
      create(:kong_entity, kong_connection: connection, entity_type: "route", name: "old", parent_type: "service",
        parent_kong_id: service.kong_id, data: { "name" => "old", "paths" => %w[/billing], "hosts" => [], "methods" => [] })
      post routes_path, params: route_params.merge(service_id: service.kong_id)
      get change_plan_path(ChangePlan.last)
      expect(response).to have_http_status(:ok)
    end

    it "answers the overlap check from the read-model" do
      create(:kong_entity, kong_connection: connection, entity_type: "route", name: "old", parent_type: "service",
        parent_kong_id: service.kong_id, data: { "name" => "old", "paths" => %w[/billing], "hosts" => [], "methods" => [] })
      get routes_overlap_path, params: { paths: %w[/billing] }
      expect(response.parsed_body["overlaps"]).to contain_exactly(include("route_name" => "old", "reason" => "exact"))
    end

    it "sends an unknown service back to the service list" do
      get new_route_path(service_id: SecureRandom.uuid)
      expect(response).to redirect_to(entities_path(type: "service"))
      expect(flash[:alert]).to be_present
    end
  end

  context "PR mode" do
    let(:connection) { create(:kong_connection, admin_url: "https://kong.test",
      project_env: create(:project_env, name: "uat", apply_mode: "pr", source: "registry", select_tags: %w[managed-by-kongctl])) }

    it "adds a route under a service that exists only in the changeset, with no write call" do
      sign_in_to(connection, access: :ro)
      post services_path, params: { service_form: { name: "billing", protocol: "http", host: "billing.internal" } }
      service_plan = ChangePlan.last

      get new_route_path(service_id: service_plan.provisional_kong_id)
      expect(response).to have_http_status(:ok)

      post routes_path, params: route_params.merge(service_id: service_plan.provisional_kong_id)
      route_plan = ChangePlan.last
      expect(route_plan).to have_attributes(changeset_id: service_plan.changeset_id, parent_kong_id: service_plan.provisional_kong_id)
      expect(a_request(:any, /kong\.test/).with { |req| req.method != :get && req.uri.path != Kong::AccessProbe::PROBE_PATH }).not_to have_been_made
    end
  end
end
