# spec/requests/services_spec.rb
require "rails_helper"

# The login access probe (a PATCH the router answers 404) is the sign-in, not
# a write; every other non-GET to Kong fails these examples.
RSpec.describe "Create service", type: :request do
  include SignInHelper # from R1.7

  context "direct mode, read-write" do
    let(:connection) { create(:kong_connection, admin_url: "https://kong.test", project_env: create(:project_env, apply_mode: "direct", select_tags: %w[team-a])) }

    it "checks the form, then opens the plan review with the environment's tags" do
      sign_in_to(connection, access: :rw)
      stub_request(:post, "https://kong.test/schemas/services/validate").to_return(status: 200, body: "{}")
      post services_path, params: { service_form: { name: "billing", protocol: "http", host: "billing.internal" } }
      plan = ChangePlan.last
      expect(response).to redirect_to(change_plan_path(plan))
      expect(plan.after["tags"]).to eq(%w[team-a])
    end

    it "re-renders with field errors and makes no plan" do
      sign_in_to(connection, access: :rw)
      post services_path, params: { service_form: { name: "bad name", host: "" } }
      expect(response).to have_http_status(:unprocessable_entity)
      expect(ChangePlan.count).to eq(0)
    end
  end

  context "PR mode" do
    let(:connection) { create(:kong_connection, admin_url: "https://kong.test",
      project_env: create(:project_env, name: "uat", apply_mode: "pr", source: "registry", select_tags: %w[managed-by-kongctl])) }

    it "adds to the changeset and never writes to Kong" do
      sign_in_to(connection, access: :ro)
      post services_path, params: { service_form: { name: "billing", protocol: "http", host: "billing.internal" } }
      expect(response).to redirect_to(changeset_path(ChangePlan.last.changeset))
      expect(a_request(:any, /kong\.test/).with { |req| req.method != :get && req.uri.path != Kong::AccessProbe::PROBE_PATH }).not_to have_been_made
    end
  end

  it "hides and refuses create for a read-only credential in direct mode" do
    connection = create(:kong_connection, admin_url: "https://kong.test", project_env: create(:project_env, apply_mode: "direct"))
    sign_in_to(connection, access: :ro)
    get new_service_path
    expect(response).to redirect_to(entities_path(type: "service"))
    get entities_path(type: "service")
    expect(response.body).not_to include(new_service_path)
  end
end
