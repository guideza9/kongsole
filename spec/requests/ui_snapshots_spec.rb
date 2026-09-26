require "rails_helper"
require Rails.root.join("spec/support/ui_snapshots")
require Rails.root.join("spec/support/bare_git_repo")

# Renders real pages to tmp/ui-snapshots/*.html so `npx impeccable detect`
# (which cannot read .erb) has something to scan. Writes only when
# UI_SNAPSHOTS=1; otherwise each example just proves its page renders.
#
#   UI_SNAPSHOTS=1 bundle exec rspec spec/requests/ui_snapshots_spec.rb
#   npx impeccable detect --json tmp/ui-snapshots
RSpec.describe "UI snapshots", type: :request do
  include UiSnapshots

  it "writes the connections index with the stylesheet inlined" do
    create(:kong_connection, name: "dev-1")
    get connections_path
    path = snapshot!("connections-index", force: true, dir: Pathname(Dir.mktmpdir))
    html = File.read(path)
    expect(html).to include("<style>")
    expect(html).not_to include('rel="stylesheet" href="/assets')
  end

  # CI runs the suite without `tailwindcss:build`, and the build is gitignored.
  it "still writes a snapshot when the Tailwind build is missing" do
    stub_const("UiSnapshots::TAILWIND", Rails.root.join("tmp", "no-such-tailwind.css"))
    create(:kong_connection, name: "dev-1")
    get connections_path
    html = File.read(snapshot!("connections-index", force: true, dir: Pathname(Dir.mktmpdir)))
    expect(html).to include("<style>")
  end

  describe "pages" do
    let(:connection) { create(:kong_connection, admin_url: "https://kong-admin.test", credential_mode: "session") }

    def sign_in(conn = connection)
      base = conn.admin_url
      stub_request(:get, "#{base}/").to_return(status: 200, body: { version: "3.7.0" }.to_json)
      stub_request(:patch, "#{base}#{Kong::AccessProbe::PROBE_PATH}")
        .to_return(status: 404, body: { message: "Not found" }.to_json)
      stub_request(:get, "#{base}/consumers/alice").to_return(status: 200, body: { tags: [] }.to_json)
      stub_request(:get, "#{base}/routes").to_return(status: 200, body: { data: [], offset: nil }.to_json)
      # Entity forms read Kong's schema for reference rows (R3.3); a 404 means hints only.
      stub_request(:get, %r{\A#{Regexp.escape(base)}/schemas/[a-z_]+\z}).to_return(status: 404, body: { message: "Not found" }.to_json)
      post login_connection_path(conn), params: { username: "alice", password: "pw" }
    end

    it "login" do
      get login_connection_path(connection)
      snapshot!("login")
    end

    it "login on uat (R3.6)" do
      get login_connection_path(create(:kong_connection, name: "uat-1", env: "uat", rank: 2, apply_mode: "pr"))
      snapshot!("login-uat")
    end

    it "health" do
      create(:kong_connection, name: "sit", last_status: "ok")
      get health_path
      snapshot!("health")
    end

    it "connections index" do
      create(:kong_connection, name: "dev-1")
      get connections_path
      snapshot!("connections-index")
    end

    it "connections index grouped by project (R1.8)" do
      Kong::ConnectionsConfigLoader.call(path: Rails.root.join("spec/fixtures/connections/two_projects.yml"))
      KongConnection.find_by!(name: "project-a/dev").update!(last_status: "ok", access_level: "rw", credential_kind: "personal")
      KongConnection.find_by!(name: "project-a/uat").update!(last_status: "ok", access_level: "ro", credential_kind: "shared")
      KongConnection.find_by!(name: "project-x/nonprod").update!(last_status: "unreachable")
      local = create(:project, key: "payments", name: "Payments", source: "local", network_note: "Reachable from the office network")
      create(:kong_connection, project_env: create(:project_env, project: local, name: "dev", position: 1), admin_url: "http://localhost:8101")
      create(:project_env, project: local, name: "sit", position: 2, apply_mode: nil)
      create(:project, key: "onboarding", name: "Onboarding", source: "local")
      get connections_path
      snapshot!("connections-index-projects")
    end

    it "connections as a list of projects to log in from, and filtered (R1.19)" do
      Kong::ConnectionsConfigLoader.call(path: Rails.root.join("spec/fixtures/connections/two_projects.yml"))
      KongConnection.find_by!(name: "project-x/nonprod").update!(last_status: "unreachable")
      %w[Billing Cards Loans Onboarding].each_with_index do |name, i|
        project = create(:project, key: name.downcase, name: name, source: "local")
        %w[dev sit uat].first(i % 3 + 1).each_with_index do |env, j|
          create(:kong_connection, project_env: create(:project_env, project: project, name: env, position: j + 1), admin_url: "http://localhost:#{8100 + i * 10 + j}")
        end
      end
      get connections_path
      snapshot!("connections-launcher")
      get connections_path(q: "project-a uat")
      snapshot!("connections-launcher-filtered")
    end

    it "a project's page, local and from connections.yml (R1.20)" do
      Kong::ConnectionsConfigLoader.call(path: Rails.root.join("spec/fixtures/connections/two_projects.yml"))
      KongConnection.find_by!(name: "project-a/uat").update!(last_status: "ok", access_level: "ro", credential_kind: "shared")
      get project_path(Project.find_by!(key: "project-a"))
      snapshot!("project-show-registry")
      local = create(:project, key: "payments", name: "Payments", source: "local", network_note: "Reachable from the office network")
      create(:kong_connection, project_env: create(:project_env, project: local, name: "dev", position: 1), admin_url: "http://localhost:8101", last_status: "unreachable")
      create(:project_env, project: local, name: "sit", position: 2, apply_mode: nil)
      get project_path(local)
      snapshot!("project-show-local")
    end

    it "project and env forms (R1.9)" do
      project = create(:project, key: "payments", name: "Payments", source: "local")
      get new_project_path
      snapshot!("projects-new")
      get new_project_env_path(project_id: project.id)
      snapshot!("project-envs-new")
      env = create(:project_env, project: project, name: "uat", position: 3, apply_mode: nil)
      get edit_project_env_path(env)
      snapshot!("project-envs-edit-known")
    end

    it "a registry connection's page (R1.9)" do
      Kong::ConnectionsConfigLoader.call(path: Rails.root.join("spec/fixtures/connections/two_projects.yml"))
      get connection_path(KongConnection.find_by!(name: "project-a/uat"))
      snapshot!("connection-show-registry")
    end

    it "header with the env switcher (R1.10)" do
      project = create(:project, key: "payments", name: "Payments")
      create(:kong_connection, project_env: create(:project_env, project: project, name: "dev", position: 1), admin_url: "http://localhost:8101")
      create(:project_env, project: project, name: "sit", position: 2)
      create(:kong_connection, project_env: create(:project_env, project: project, name: "pt", position: 3, rank: 1), admin_url: "http://localhost:8103")
      uat = create(:kong_connection, project_env: create(:project_env, project: project, name: "uat", position: 4, apply_mode: "pr", source: "registry"),
        admin_url: "https://kong-uat.test")
      sign_in(uat)
      get health_path
      snapshot!("header-switcher")
    end

    it "connections new" do
      get new_connection_path
      snapshot!("connections-new")
    end

    Kong::EntityTypes::DEFINITIONS.each_key do |type|
      it "entities index: #{type} tab" do
        sign_in
        get entities_path(type: type)
        snapshot!("entities-index-#{type}")
      end
    end

    it "entity show" do
      sign_in
      entity = create(:kong_entity, kong_connection: connection, name: "payments-api", data: { "host" => "backend.internal" })
      get entity_path(entity)
      snapshot!("entity-show")
    end

    it "entities index and entity show where nothing can be written (R1.14)" do
      unset = create(:kong_connection, admin_url: "https://kong-unset.test", apply_mode: nil, credential_mode: "session")
      sign_in(unset)
      upstream = create(:kong_entity, kong_connection: unset, entity_type: "upstream", name: "payments-up")
      get entities_path(type: "upstream")
      snapshot!("entities-index-write-blocked")
      get entity_path(upstream)
      snapshot!("entity-show-write-blocked")
    end

    %w[upstream certificate ca_certificate].each do |type|
      it "entities new: #{type}" do
        sign_in
        get new_entity_path(type: type)
        snapshot!("entities-new-#{type}")
      end
    end

    it "entities new: target (under its upstream)" do
      sign_in
      upstream = create(:kong_entity, kong_connection: connection, entity_type: "upstream", name: "payments-upstream")
      get new_entity_path(type: "target", parent_kong_id: upstream.kong_id)
      snapshot!("entities-new-target")
    end

    it "entities new: sni (under its certificate)" do
      sign_in
      certificate = create(:kong_entity, kong_connection: connection, entity_type: "certificate", name: "api.example.test")
      get new_entity_path(type: "sni", parent_kong_id: certificate.kong_id)
      snapshot!("entities-new-sni")
    end

    it "plugins new: catalog step" do
      sign_in
      connection.update!(plugins_available: { "available_on_server" => { "acl" => {}, "rate-limiting" => {} } })
      get new_plugin_path
      snapshot!("plugins-new-catalog")
    end

    it "plugins new: the catalog, custom and bundled, entered from a service (R4.6)" do
      sign_in
      loaded = YAML.safe_load_file(Rails.root.join("config/kong_bundled_plugins.yml"))
        .each_with_index.to_h { |name, i| [ name, { "version" => "3.7.0", "priority" => 1000 - (i * 10) } ] }
      connection.update!(plugins_available: { "available_on_server" => loaded.merge(
        "team-headers" => { "version" => "1.0.0", "priority" => 800 },
        "team-auth-with-a-rather-long-plugin-name" => { "version" => "0.3.0", "priority" => 1005 }) })
      service = create(:kong_entity, kong_connection: connection, entity_type: "service", name: "payments-api")
      get new_plugin_path(scope_type: "service", scope_kong_id: service.kong_id)
      snapshot!("plugins-new-catalog-r46")
    end

    it "plugins new: config step with the scope picker (R4.6)" do
      sign_in
      stub_request(:get, "https://kong-admin.test/schemas/plugins/rate-limiting")
        .to_return(status: 200, body: File.read(Rails.root.join("spec/fixtures/schemas/rate_limiting_like.json")))
      12.times { |i| create(:kong_entity, kong_connection: connection, entity_type: "service", name: "service-#{i}") }
      create(:kong_entity, kong_connection: connection, entity_type: "route", name: "payments-route")
      get new_plugin_path(plugin_name: "rate-limiting")
      snapshot!("plugins-new-config-scope-r46")
    end

    describe "plugin config form (R4.7)" do
      let(:rl_schema) { File.read(Rails.root.join("spec/fixtures/schemas/rate_limiting_like.json")) }
      let(:lambda_schema) do
        { fields: [ { config: { type: "record", fields: [
          { aws_key: { type: "string", encrypted: true, referenceable: true } },
          { aws_secret: { type: "string", encrypted: true, referenceable: true } },
          { aws_region: { type: "string", description: "The AWS region of the function." } },
          { function_name: { type: "string", required: true } },
          { timeout: { type: "number", default: 60_000, required: true } },
          { invocation_type: { type: "string", default: "RequestResponse", one_of: %w[RequestResponse Event DryRun] } },
          { forward_request_body: { type: "boolean", default: false } }
        ] } } ] }.to_json
      end

      it "rate-limiting, direct, sent back with errors" do
        sign_in
        stub_request(:get, "https://kong-admin.test/schemas/plugins/rate-limiting").to_return(status: 200, body: rl_schema)
        post plugins_path, params: { plugin_name: "rate-limiting", plugin: { config: { minute: "1e3", policy: "cluster", redis: "{" } } }
        snapshot!("plugins-config-rate-limiting-errors", status: :unprocessable_entity)
      end

      it "aws-lambda with secrets, on a PR env, with a schema that differs on another env" do
        env = create(:project_env, name: "uat", apply_mode: "pr", source: "registry", select_tags: %w[managed-by-kongctl])
        pr_connection = create(:kong_connection, admin_url: "https://kong-uat.test", project_env: env, kong_version: "3.7.1")
        other = create(:kong_connection, kong_version: "3.8.0",
          project_env: create(:project_env, project: env.project, name: "prod", position: 9, rank: 3, apply_mode: "pr", source: "registry"))
        KongSchema.create!(kong_connection: other, kind: "plugin", name: "aws-lambda", kong_version: "3.8.0", digest: "x", body: {}, fetched_at: Time.current)
        sign_in_to(pr_connection, access: :ro)
        stub_request(:get, "https://kong-uat.test/schemas/plugins/aws-lambda").to_return(status: 200, body: lambda_schema)
        service = create(:kong_entity, kong_connection: pr_connection, entity_type: "service", name: "payments-api")
        get new_plugin_path(plugin_name: "aws-lambda", scope_type: "service", scope_kong_id: service.kong_id)
        snapshot!("plugins-config-aws-lambda-pr")
      end

      it "a custom plugin described by its metadata file" do
        sign_in
        connection.update!(plugins_available: { "available_on_server" => { "team-auth" => { "version" => "0.3.0", "priority" => 1005 } } })
        allow(Kong::PluginCatalog).to receive(:for).and_wrap_original do |original, conn, **|
          original.call(conn, metadata_dir: Rails.root.join("spec/fixtures/custom_plugins"))
        end
        stub_request(:get, "https://kong-admin.test/schemas/plugins/team-auth").to_return(status: 200, body: { fields: [ { config: {
          type: "record", fields: [ { upstream_header: { type: "string", default: "X-Team" } }, { shared_key: { type: "string", referenceable: true, required: true } } ] } } ] }.to_json)
        get new_plugin_path(plugin_name: "team-auth")
        snapshot!("plugins-config-custom")
      end

      it "an admin-path scope, read-only" do
        sign_in
        admin_route_id = "dddddddd-dddd-dddd-dddd-dddddddddddd"
        connection.update!(admin_path_fingerprint: { "route_ids" => [ admin_route_id ] })
        stub_request(:get, "https://kong-admin.test/schemas/plugins/rate-limiting").to_return(status: 200, body: rl_schema)
        get new_plugin_path(plugin_name: "rate-limiting", scope_type: "route", scope_kong_id: admin_route_id)
        snapshot!("plugins-config-admin-path")
      end
    end

    it "plugins new: config step" do
      sign_in
      stub_request(:get, "https://kong-admin.test/schemas/plugins/rate-limiting").to_return(status: 200, body: {
        fields: [ { config: { fields: [
          { second: { type: "integer", description: "Requests per second.", required: false } },
          { policy: { type: "string", default: "local", one_of: %w[local redis] } }
        ] } } ]
      }.to_json)
      get new_plugin_path(plugin_name: "rate-limiting")
      snapshot!("plugins-new-config")
    end

    it "change plan show: direct" do
      sign_in
      get change_plan_path(create(:change_plan, kong_connection: connection))
      snapshot!("change-plan-direct")
    end

    it "change plan show: pr" do
      sign_in
      plan = create(:change_plan, kong_connection: connection, apply_mode: "pr", before: { "name" => "svc" }, after: { "name" => "svc" })
      get change_plan_path(plan)
      snapshot!("change-plan-pr")
    end

    it "change plan show: delete" do
      sign_in
      get change_plan_path(create(:change_plan, :delete, kong_connection: connection))
      snapshot!("change-plan-delete")
    end

    it "change plans index" do
      sign_in
      create(:change_plan, kong_connection: connection, apply_mode: "pr", before: { "name" => "svc" }, after: { "name" => "svc" })
      get change_plans_path
      snapshot!("change-plans-index")
    end

    it "audit events index" do
      sign_in
      create(:audit_event, kong_connection: connection)
      get audit_events_path
      snapshot!("audit-events-index")
    end

    it "personal access tokens index" do
      sign_in
      get personal_access_tokens_path
      snapshot!("tokens-index")
    end

    it "personal access tokens new" do
      sign_in
      get new_personal_access_token_path
      snapshot!("tokens-new")
    end

    it "layout with compact hints (R3.4)" do
      cookies[:kongsole_hints] = "compact"
      create(:kong_connection, name: "dev-1")
      get connections_path
      expect(response.body).to include(I18n.t("hints.ui.toggle.show"))
      snapshot!("layout-compact-hints")
    end

    it "an alert with its cause and next step (R3.4)" do
      sign_in
      entity = create(:kong_entity, kong_connection: connection, kong_id: "47474747-4747-4747-4747-474747474747", name: "payments-api")
      stub_request(:get, "https://kong-admin.test/services/#{entity.kong_id}")
        .to_return(status: 404, body: { message: "no Route matched with those values" }.to_json)
      patch entity_path(entity), params: { tags: "payment", enabled: "1" }
      follow_redirect!
      expect(response.body).to include(I18n.t("hints.ui.next_step"), CGI.escapeHTML(I18n.t("hints.errors.route_not_matched.next_step")))
      snapshot!("alert-error-explanation")
    end

    it "certificates expiring" do
      sign_in
      get expiring_certificates_path
      snapshot!("certificates-expiring")
    end
    it "service form: direct, PR and refused (R2.5)" do
      connection.update!(access_level: "rw")
      sign_in
      get new_service_path
      snapshot!("service-new")

      post services_path, params: { service_form: { name: "billing api", host: "", port: "70000", path: "api", read_timeout: "0" } }
      snapshot!("service-new-errors", status: :unprocessable_entity)

      pr = create(:kong_connection, name: "uat-pr", admin_url: "https://kong-uat.test", env: "uat", rank: 2, apply_mode: "pr",
        select_tags: %w[managed-by-kongctl])
      sign_in(pr)
      get new_service_path
      snapshot!("service-new-pr")
    end

    it "route form and the review of an overlapping route (R2.6)" do
      connection.update!(access_level: "rw")
      sign_in
      service = create(:kong_entity, kong_connection: connection, entity_type: "service", name: "billing")
      { "billing-legacy" => %w[/billing], "bill" => %w[/bill], "billing-versions" => [ "~/billing/v[0-9]+$" ] }.each do |name, paths|
        create(:kong_entity, kong_connection: connection, entity_type: "route", name: name, parent_type: "service",
          parent_kong_id: service.kong_id, data: { "name" => name, "paths" => paths, "hosts" => [], "methods" => [] })
      end

      get new_route_path(service_id: service.kong_id)
      snapshot!("route-new")

      post routes_path, params: { service_id: service.kong_id, route_form: { name: "", paths: "billing", hosts: "api.*.example.com" } }
      snapshot!("route-new-errors", status: :unprocessable_entity)

      post routes_path, params: { service_id: service.kong_id,
        route_form: { name: "billing-v1", protocols: %w[http https], paths: "/billing", methods: %w[GET POST] } }
      get change_plan_path(ChangePlan.last)
      snapshot!("change-plan-route-overlap")
    end

  end
  # R8.9: the changeset pages in each state.
  describe "changesets" do
    include BareGitRepo
    include SignInHelper

    let(:repo) { bare_git_repo(path: "uat/kong.yaml", select_tags: %w[managed-by-kongctl]) }
    let(:pr) do
      pr_connection_for(repo, path: "uat/kong.yaml", select_tags: %w[managed-by-kongctl]).tap { _1.update!(admin_url: "https://kong-uat.test") }
    end
    let(:changeset) { create(:changeset, kong_connection: pr, base_git_sha: head_sha(repo), actor_operator: "somchai@example.com") }

    def item(name, position, operation: "create", actor_kind: "human")
      create(:change_plan, changeset: changeset, kong_connection: pr, position: position, apply_mode: "pr", operation: operation,
        actor_kind: actor_kind, entity_type: "service", provisional_kong_id: SecureRandom.uuid, target_kong_id: nil, before: {},
        diff: { "operation" => "create" }, after: { "name" => name, "host" => "#{name}.internal", "tags" => %w[managed-by-kongctl] })
    end

    before do
      sign_in_to(pr, access: :ro)
      allow(Kong::DeckCli).to receive(:validate).and_return(true)
      allow(Kong::DeckCli).to receive(:diff).and_return({ "changes" => { "creating" => [ { "kind" => "service", "name" => "billing" } ], "updating" => [], "deleting" => [] } })
    end

    it "empty, open, preview, blocked and pushed" do
      get changeset_path(changeset)
      snapshot!("changeset-empty")

      item("billing", 1)
      item("ledger-reconciliation-service-for-business-customers", 2, actor_kind: "agent")
      get changeset_path(changeset)
      snapshot!("changeset-open")

      push_empty_commit(repo)
      get preview_changeset_path(changeset)
      snapshot!("changeset-preview")

      pr.project_env.project.update!(delete_threshold: 1)
      allow(Kong::DeckCli).to receive(:diff).and_return({ "changes" => { "creating" => [], "updating" => [],
        "deleting" => [ { "kind" => "service", "name" => "a" }, { "kind" => "service", "name" => "b" } ] } })
      get preview_changeset_path(changeset)
      snapshot!("changeset-blocked")

      pr.project_env.project.update!(git_web_url: "https://git.example/team/kong-config/tree/{branch}")
      pr.save!
      changeset.update!(status: "submitted", branch: "kongctl/changeset-#{changeset.id}", commit_sha: "3f9c2a7b" * 5,
        submitted_at: Time.current, submitted_by: "kong-admin",
        pr_body: Kong::PrBody.markdown(changeset, deck_diff: { "changes" => { "creating" => [ {} ], "updating" => [], "deleting" => [] } },
          gate: Kong::CiGate::Result.new(passed: true, reasons: []), operator: "somchai@example.com"))
      changeset.change_plans.update_all(status: "applied")
      get changeset_path(changeset)
      snapshot!("changeset-submitted")
    end

  end
end
