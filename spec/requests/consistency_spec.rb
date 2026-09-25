require "rails_helper"

# The console says the same thing the same way: times as one local stamp,
# states as one badge, and "pick one of these" as one tab. These read the
# rendered pages, so a page that drifts back to its own dialect fails here.
RSpec.describe "Console consistency", type: :request do
  let(:connection) { create(:kong_connection, admin_url: "https://kong-admin.test", credential_mode: "session") }

  def sign_in
    stub_request(:get, "https://kong-admin.test/").to_return(status: 200, body: { version: "3.7.0" }.to_json)
    stub_request(:patch, "https://kong-admin.test#{Kong::AccessProbe::PROBE_PATH}").to_return(status: 404, body: { message: "Not found" }.to_json)
    stub_request(:get, "https://kong-admin.test/consumers/alice").to_return(status: 200, body: { tags: [] }.to_json)
    stub_request(:get, "https://kong-admin.test/routes").to_return(status: 200, body: { data: [], offset: nil }.to_json)
    # Entity forms read Kong's schema for reference rows (R3.3); a 404 means hints only.
    stub_request(:get, %r{\Ahttps://kong-admin\.test/schemas/[a-z_]+\z}).to_return(status: 404, body: { message: "Not found" }.to_json)
    post login_connection_path(connection), params: { username: "alice", password: "pw" }
  end

  def page
    Nokogiri::HTML(response.body)
  end

  # R3: every field says what it is for, and every empty page how to begin.
  describe "hints" do
    # Visible form fields whose aria-describedby is missing or points at no text.
    def undescribed_fields
      page.css("main input, main select, main textarea")
        .reject { |el| %w[hidden submit button].include?(el["type"]) }
        .reject do |el|
          ids = el["aria-describedby"].to_s.split
          ids.any? && ids.all? { |id| page.at_css("[id='#{id}']")&.text.to_s.strip.present? }
        end
        .map { |el| el["name"] || el["id"] }
    end

    it "describes every field on the connection form" do
      get new_connection_path
      expect(undescribed_fields).to eq([])
    end

    it "describes every field on the login form" do
      get login_connection_path(connection)
      expect(undescribed_fields).to eq([])
    end

    it "describes every field on the token form" do
      sign_in
      create(:kong_connection, name: "dev-stored", credential_mode: "stored")
      get new_personal_access_token_path
      expect(undescribed_fields).to eq([])
    end

    it "describes every field on the entity edit form and the entity filter" do
      sign_in
      entity = create(:kong_entity, kong_connection: connection, name: "payments-api")
      stub_request(:get, "https://kong-admin.test/services/#{entity.kong_id}")
        .to_return(status: 200, body: { id: entity.kong_id, name: "payments-api", tags: [] }.to_json)

      get edit_entity_path(entity)
      expect(undescribed_fields).to eq([])

      get entities_path(type: "service")
      expect(undescribed_fields).to eq([])
    end

    it "describes every field on the project form (R1.9)" do
      get new_project_path
      expect(undescribed_fields).to eq([])
    end

    it "describes every field on the env form, fixing a known name's rank and asking for any other (R1.9)" do
      project = create(:project, source: "local")
      get new_project_env_path(project_id: project.id)
      expect(undescribed_fields).to eq([])
      rank = page.at_css("select[name='project_env[rank]']")
      expect(rank["required"]).to be_present
      expect(rank.at_css("option[selected]")).to be_nil
      expect(page.css("select[name='project_env[apply_mode]'] option").map { |o| o["value"] }).to eq([ "", "direct" ])

      env = create(:project_env, project: project, name: "uat", apply_mode: nil)
      get edit_project_env_path(env)
      expect(page.text).to include(I18n.t("hints.fields.project_env.rank_fixed", rank: 2))
      expect(page.at_css("select[name='project_env[rank]']")&.[]("disabled")).to be_present
    end

    it "shows a registry connection read-only, pointing at connections.yml (R1.9)" do
      connection = create(:kong_connection, project_env: create(:project_env, source: "registry", apply_mode: "pr"))
      get connection_path(connection)
      expect(page.text).to include("config/connections.yml")
      expect(page.css("a").map { |a| a.text.strip }).not_to include("Edit")
    end

    it "preselects the env a Connect link came from (R1.9)" do
      env = create(:project_env, source: "local", project: create(:project, source: "local"))
      get new_connection_path(project_env_id: env.id)
      expect(page.at_css("select[name='kong_connection[project_env_id]'] option[selected]")&.[]("value")).to eq(env.id.to_s)
    end

    it "describes the JSON editor on a create form and the plugin config step" do
      sign_in
      get new_entity_path(type: "upstream")
      expect(undescribed_fields).to eq([])

      stub_request(:get, "https://kong-admin.test/schemas/plugins/cors")
        .to_return(status: 200, body: { fields: [ { config: { fields: [] } } ] }.to_json)
      get new_plugin_path(plugin_name: "cors")
      expect(undescribed_fields).to eq([])
    end

    it "tells a connection that has never synced apart from a filter that matches nothing" do
      sign_in
      get entities_path(type: "service")
      expect(response.body).to include(I18n.t("hints.empty_states.entities.never_synced.title"))

      create(:kong_entity, kong_connection: connection, name: "payments-api")
      get entities_path(type: "service", q: "nothing-like-this")
      expect(response.body).to include(I18n.t("hints.empty_states.entities.no_match.title", type: "services"))
    end

    it "explains what a delete does before the review asks to confirm it" do
      sign_in
      get change_plan_path(create(:change_plan, :delete, kong_connection: connection))
      expect(response.body).to include(I18n.t("hints.risks.delete_entity.title"))
    end

    it "says Kong refuses to delete a service that still has routes, rather than taking them with it" do
      sign_in
      get change_plan_path(create(:change_plan, :delete, kong_connection: connection))
      expect(response.body).to include(I18n.t("hints.risks.delete_entity.body"))
      expect(I18n.t("hints.risks.delete_entity.body")).to match(/refuses/i).and(satisfy { |body| !body.include?("takes its routes") })
    end

    it "keeps the admin-path warning for the admin path, and asks for the entity's own name" do
      sign_in
      admin_id = "abababab-abab-abab-abab-abababababab"
      connection.update!(admin_path_fingerprint: { "service_id" => admin_id })
      get change_plan_path(create(:change_plan, :delete, kong_connection: connection, target_kong_id: admin_id,
        before: { "id" => admin_id, "name" => "admin-api", "tags" => [] }))
      expect(response.body).to include(I18n.t("hints.risks.delete_admin_path.title"))
      expect(I18n.t("hints.risks.delete_admin_path.body")).not_to include("connection name")
    end

    it "warns about a protected entity as protected, not as the admin path" do
      sign_in
      get change_plan_path(create(:change_plan, :delete, kong_connection: connection,
        before: { "id" => SecureRandom.uuid, "name" => "payments-api", "tags" => [ "protected" ] }))
      expect(response.body).to include(I18n.t("hints.risks.delete_protected.title"))
      expect(response.body).not_to include(I18n.t("hints.risks.delete_admin_path.title"))
    end

    it "only promises a pull request on a uat login whose connection is in PR mode" do
      direct = create(:kong_connection, name: "uat-direct", env: "uat", rank: 2, apply_mode: "direct")
      get login_connection_path(direct)
      expect(response.body).not_to include(I18n.t("hints.risks.rank_2_login.pr_note"))

      pr = create(:kong_connection, name: "uat-pr", env: "uat", rank: 2, apply_mode: "pr")
      get login_connection_path(pr)
      expect(response.body).to include(I18n.t("hints.risks.rank_2_login.pr_note"))
    end

    it "explains what a uat login means before the credential is typed" do
      uat = create(:kong_connection, name: "uat-1", env: "uat", rank: 2, apply_mode: "pr")
      get login_connection_path(uat)
      expect(response.body).to include(I18n.t("hints.risks.rank_2_login.title", env: "UAT"))
    end
  end

  describe "health" do
    it "gives every connection a Log in and a Details action, and reads its policy in words and badges" do
      other = create(:kong_connection, name: "uat-ro", env: "uat", access_level: "ro", credential_kind: "shared",
        last_connected_at: Time.utc(2026, 9, 21, 14, 5), admin_path_fingerprint: { "service_id" => "s1" })

      get health_path

      row = page.css("tbody tr").find { |tr| tr.at_css("[title='#{other.name}']") } # R1.10: the badge names project · env; its title is project/env
      expect(row.css("a").map { |a| [ a.text.strip, a["href"] ] }).to eq([ [ "Log in", login_connection_path(other) ], [ "Details", connection_path(other) ] ])
      expect(row.text).to include("Read-only").and include("Shared")
      expect(row.at_css(".chip-ok").text).to include("Guarded")
      expect(row.at_css("time[data-controller='local-time']")["datetime"]).to eq("2026-09-21T14:05:00Z")
      expect(page.css("thead th").map { |th| th.text.strip }).to include("Actions")
    end

    it "says a connection with no admin path found is Unknown, in a badge" do
      fresh = create(:kong_connection, name: "fresh")

      get health_path

      expect(page.css("tbody tr").find { |tr| tr.at_css("[title='#{fresh.name}']") }.css(".chip-neutral").map(&:text).join).to include("Unknown")
    end
  end

  describe "timestamps" do
    before { sign_in }

    it "uses the shared local timestamp in the audit log" do
      create(:audit_event, kong_connection: connection)

      get audit_events_path

      expect(page.css("tbody time[data-controller='local-time']").size).to eq(1)
      expect(response.body).not_to match(/\d{2} [A-Z][a-z]{2} \d{2}:\d{2}/)
    end

    it "uses it for an entity's times, in the list and on its page" do
      entity = create(:kong_entity, kong_connection: connection, name: "payments-api")

      get entities_path
      expect(page.css("#entities-list time[data-controller='local-time']").size).to eq(1)

      get entity_path(entity)
      expect(page.css("dl time[data-controller='local-time']").size).to be >= 3
    end

    it "uses it for a token's dates, and shows a revoked one as a badge" do
      token = create(:personal_access_token, issued_by_username: "alice")
      token.update!(revoked_at: Time.current)

      get personal_access_tokens_path

      expect(page.css("time[data-controller='local-time']").size).to be >= 2
      expect(page.at_css(".chip-danger").text).to include("Revoked")
    end
  end

  describe "tabs" do
    before { sign_in }

    it "uses one tab style for the entity types, the expiry window and the upstream preset" do
      get entities_path
      expect(page.css("nav[aria-label='Entity types'] a").map { |a| a["class"] }.uniq).to eq([ "tab" ])

      get expiring_certificates_path
      expect(page.css("nav[aria-label='Window'] a").map { |a| a["class"] }.uniq).to eq([ "tab" ])

      get new_entity_path(type: "upstream")
      expect(page.css("nav[aria-label='Start from'] a").map { |a| a["class"] }.uniq).to eq([ "tab" ])
    end

    it "marks the current tab by aria-current alone, never a per-page class" do
      get expiring_certificates_path(days: 30)

      current = page.css("nav[aria-label='Window'] a[aria-current]")
      expect(current.map { |a| a.text.strip }).to eq([ "30 days" ])
    end
  end

  # R1.8: the Connections page reads as projects, each with its envs in the
  # project's own order.
  # R1.19: the rows below moved from the connections page to each project's
  # page (R1.18); the conditions on them are unchanged.
  describe "a project's page" do
    let!(:project_a) { create(:project, key: "project-a", name: "Project A", source: "registry", network_note: "Reachable from the NONPROD VPN only") }
    let!(:project_x) { create(:project, key: "project-x", name: "Project X", source: "local") }

    before do
      create(:kong_connection, project_env: create(:project_env, project: project_a, name: "uat", position: 2, apply_mode: "pr", source: "registry"))
      create(:kong_connection, project_env: create(:project_env, project: project_a, name: "dev", position: 1, apply_mode: "direct", source: "registry"))
      create(:kong_connection, project_env: create(:project_env, project: project_x, name: "pt", position: 1, rank: 1, apply_mode: nil),
        last_status: "unreachable")
      create(:project, key: "empty", name: "Empty Project", source: "local")
    end

    def section(name)
      page.css("section").find { |s| s.at_css("h2")&.text&.strip == name }
    end

    it "gives the project a heading and lists its envs in the project's order" do
      get project_path(project_a)
      expect(page.css("section h2").map { |h| h.text.strip }).to include("Project A")
      envs = section("Project A").css("[data-env-name]").map { |row| row["data-env-name"] }
      expect(envs).to eq(%w[dev uat])
    end

    it "says where each project and env is edited" do
      get project_path(project_a)
      expect(section("Project A").text).to include("From connections.yml")
      get project_path(project_x)
      expect(section("Project X").text).to include("Local only")
    end

    it "names the project's network, and says when this machine cannot reach an env" do
      get project_path(project_a)
      expect(section("Project A").text).to include("Reachable from the NONPROD VPN only")
      get project_path(project_x)
      expect(section("Project X").text).to include("Unreachable from this machine")
    end

    it "says an env without an apply mode cannot be written, and gives an other env's rank" do
      get project_path(project_x)
      text = section("Project X").text
      expect(text).to include(helper_label(:unset)).and include("Other · rank 1")
    end

    it "offers Edit and Remove only on rows Kongsole owns" do
      edit_or_remove = ->(name) { section(name).css("a, button").map { |n| n.text.strip }.grep(/\A(Edit|Remove)\b/) }
      get project_path(project_a)
      expect(edit_or_remove.call("Project A")).to be_empty
      get project_path(project_x)
      expect(edit_or_remove.call("Project X")).to include("Edit", a_string_starting_with("Remove "))
    end

    # R1.15: a connected env's rank, apply mode and colour stay editable.
    it "links a connected local env to its own edit page and to its connection's, and neither on a registry env" do
      local_env = create(:project_env, source: "local", project: create(:project, key: "local-p", name: "Local P", source: "local"))
      local_conn = create(:kong_connection, project_env: local_env)
      get project_path(local_env.project)

      row = page.css(".env-row").find { |r| r["data-env-name"] == local_env.name }
      hrefs = row.css("a").map { |a| a["href"] }
      expect(hrefs).to include(edit_project_env_path(local_env), edit_connection_path(local_conn))
      get project_path(project_a)
      expect(section("Project A").css("a").map { |a| a["href"] }.grep(%r{/edit\z})).to be_empty
    end

    it "links a local connection's page to its env's edit page (R1.15)" do
      env = create(:project_env, source: "local", project: create(:project, source: "local"))
      connection = create(:kong_connection, project_env: env)
      get connection_path(connection)
      expect(page.css("main a").map { |a| a["href"] }).to include(edit_project_env_path(env))
    end

    it "explains a project with no envs yet" do
      get project_path(Project.find_by!(key: "empty"))
      expect(section("Empty Project").text).to include(I18n.t("hints.empty_states.project_envs.title"))
    end

    def helper_label(policy)
      ApplicationController.helpers.write_policy_label(policy)
    end
  end

  # R1.19: the connections page is where an env is picked to log in -- one row
  # per project, its envs as chips, a mark only where there is a problem, and
  # a menu for the rest. Everything that edits lives on the project's page.
  describe "the connections page" do
    let!(:project_a) { create(:project, key: "project-a", name: "Project A", source: "registry", network_note: "Reachable from the NONPROD VPN only") }
    let!(:project_x) { create(:project, key: "project-x", name: "Project X", source: "local") }
    let!(:a_uat) { create(:kong_connection, admin_url: "https://kong-a-uat.test", project_env: create(:project_env, project: project_a, name: "uat", position: 2, apply_mode: "pr", source: "registry")) }
    let!(:a_dev) { create(:kong_connection, admin_url: "https://kong-a-dev.test", project_env: create(:project_env, project: project_a, name: "dev", position: 1, apply_mode: "direct", source: "registry")) }
    let!(:x_pt) { create(:kong_connection, admin_url: "https://kong-x-pt.test", project_env: create(:project_env, project: project_x, name: "pt", position: 1, rank: 1, apply_mode: nil), last_status: "unreachable") }
    let!(:x_sit) { create(:project_env, project: project_x, name: "sit", position: 2) }
    let!(:empty) { create(:project, key: "empty", name: "Empty Project", source: "local") }

    def row(name)
      page.css(".launcher__row").find { |r| r.at_css(".launcher__name")&.text&.strip == name }
    end

    def chips(name)
      row(name).css(".launcher__env")
    end

    it "has one primary action, New project, and no Add connection" do
      get connections_path
      expect(page.css(".btn-primary").map { |n| n.text.strip }).to eq([ "New project" ])
      expect(page.css("main a, main button").map { |n| n.text.squish }).not_to include("Add connection")
    end

    it "gives each project one row, by name, its name linking to the project's page" do
      get connections_path
      names = page.css(".launcher__row .launcher__name")
      expect(names.map { |n| n.text.strip }).to eq([ "Empty Project", "Project A", "Project X" ])
      expect(row("Project A").at_css("a.launcher__name")["href"]).to eq(project_path(project_a))
    end

    it "lists envs in the project's order, each with a connection a link to its login" do
      get connections_path
      expect(chips("Project A").map { |c| c["data-env-name"] }).to eq(%w[dev uat])
      dev = chips("Project A").first
      expect(dev.name).to eq("a")
      expect(dev["href"]).to eq(login_connection_path(a_dev))
      expect(dev["aria-label"]).to eq("Log in to project-a/dev")
    end

    it "shows an env with no connection yet, but does not offer it" do
      get connections_path
      sit = chips("Project X").find { |c| c["data-env-name"] == "sit" }
      expect(sit.name).to eq("span")
      expect(sit["aria-disabled"]).to eq("true")
      expect(sit.text.squish).to include("no connection yet")
    end

    it "marks an env only when its last login found a problem, and names the problem" do
      get connections_path
      pt = chips("Project X").find { |c| c["data-env-name"] == "pt" }
      expect(pt.at_css(".launcher__problem")).to be_present
      expect(pt["aria-label"]).to eq("Log in to project-x/pt (Unreachable from this machine)")
      expect(chips("Project A").map { |c| c.at_css(".launcher__problem") }).to all(be_nil)
    end

    it "leaves out what belongs on the project's page" do
      get connections_path
      text = page.at_css("main").text
      [ "https://kong-a-dev.test", "Reachable from the NONPROD VPN only", "Local only", "From connections.yml",
        ApplicationController.helpers.write_policy_label(:unset) ].each { |fact| expect(text).not_to include(fact) }
      expect(page.css("main button").map { |b| b.text.squish }.grep(/\ARemove/)).to be_empty
    end

    it "keeps each project's other actions in its menu; only a local project can be edited here" do
      get connections_path
      menu = ->(name) { row(name).at_css("details.project-menu") }
      expect(menu.call("Project A").at_css("summary")["aria-label"]).to eq("Actions for Project A")
      expect(menu.call("Project A").css("a").map { |a| a.text.strip }).to eq([ "Open project" ])
      expect(menu.call("Project X").css("a").map { |a| [ a.text.strip, a["href"] ] }).to eq([
        [ "Open project", project_path(project_x) ],
        [ "Add environment", new_project_env_path(project_id: project_x.id) ],
        [ "Edit project details", edit_project_path(project_x) ]
      ])
    end

    it "says a project has no environments yet" do
      get connections_path
      expect(row("Empty Project").text).to include(I18n.t("hints.pages.connections.project_without_envs"))
    end

    it "offers the filter only once there are six projects, or a filter is in use" do
      get connections_path
      expect(page.at_css("form[role='search']")).to be_nil
      get connections_path(q: "project")
      expect(page.at_css("form[role='search'] input[name='q']")["value"]).to eq("project")
      3.times { |i| create(:project, key: "more-#{i}", name: "More #{i}") }
      get connections_path
      form = page.at_css("form[role='search'][method='get']")
      input = form.at_css("input[name='q']")
      expect(form.at_css("label[for='#{input['id']}']").text.squish).to eq(I18n.t("hints.pages.connections.filter_label"))
    end

    it "dims the envs a query did not name, and says when nothing matches" do
      get connections_path(q: "project-a uat")
      expect(page.css(".launcher__row").size).to eq(1)
      expect(chips("Project A").map { |c| [ c["data-env-name"], c["class"].include?("is-dim") ] }).to eq([ [ "dev", true ], [ "uat", false ] ])
      get connections_path(q: "nothing-here")
      expect(page.at_css("main").text).to include(I18n.t("hints.empty_states.connections_filtered.title"))
      expect(page.css("main a").map { |a| [ a.text.strip, a["href"] ] }).to include([ "Clear filter", connections_path ])
    end

    it "tells apart two projects with the same name by their keys, and shows no key otherwise" do
      create(:project, key: "project-x-2", name: "Project X", source: "local")
      get connections_path
      keys = page.css(".launcher__row").map { |r| [ r.at_css(".launcher__name").text.strip, r.at_css(".launcher__key")&.text ] }
      expect(keys).to include([ "Project X", "project-x" ], [ "Project X", "project-x-2" ], [ "Project A", nil ])
    end

    it "marks the project of the connection in use" do
      sign_in_to(a_dev)
      get connections_path
      expect(row("Project A").text).to include("Current")
      expect(row("Project X").text).not_to include("Current")
    end
  end

  # R1.14: where nothing can be written (KongConnection#write_block_reason),
  # the write controls are not offered, and one notice says why and how to
  # change it. Where it can, every control is still there.
  describe "write controls" do
    WRITE_CONTROLS = [ "New upstream", "New global plugin", "New certificate", "New CA certificate",
                       "Edit", "Delete", "Add plugin", "Add target", "Add SNI", "Apply", "Push branch" ].freeze

    def offered_controls
      page.css("main a, main button, main input[type=submit]").map { |e| (e["value"] || e.text).squish } & WRITE_CONTROLS
    end

    def notices
      page.css("main .write-blocked")
    end

    def visit_write_pages(connection)
      upstream = create(:kong_entity, kong_connection: connection, entity_type: "upstream", name: "pay-up")
      create(:kong_entity, kong_connection: connection, entity_type: "target", name: "10.0.0.1:80", parent_kong_id: upstream.kong_id)
      plan = create(:change_plan, kong_connection: connection)
      [ entities_path(type: "upstream"), entities_path(type: "plugin"), entities_path(type: "certificate"),
        entities_path(type: "ca_certificate"), entity_path(upstream), change_plan_path(plan) ].to_h do |path|
        get path
        [ path, { controls: offered_controls, notices: notices.map { |n| n.text.squish } } ]
      end
    end

    it "offers none of them where the env's apply mode is not set, and says why once per page" do
      unset = create(:kong_connection, admin_url: "https://kong-unset.test", apply_mode: nil)
      sign_in_to(unset)
      title = I18n.t("hints.risks.write_blocked.apply_mode_unset.title", env: unset.qualified_name)

      visit_write_pages(unset).each do |path, seen|
        expect(seen[:controls]).to be_empty, "#{path} still offers #{seen[:controls].inspect}"
        expect(seen[:notices].size).to eq(1), "#{path} has #{seen[:notices].size} write-blocked notices"
        expect(seen[:notices].first).to include(title)
      end
    end

    # The way out depends on where the env is defined: only a local env can be
    # changed in the UI, so only it gets a link; a registry env names the file.
    it "links a local env with no apply mode to its own edit page" do
      unset = create(:kong_connection, admin_url: "https://kong-unset.test", apply_mode: nil)
      sign_in_to(unset)

      get entities_path(type: "upstream")
      notice = page.at_css("main .write-blocked")
      expect(notice.text.squish).to include(I18n.t("hints.risks.write_blocked.apply_mode_unset.body_local"))
      expect(notice.at_css("a[href='#{edit_project_env_path(unset.project_env)}']").text.squish)
        .to eq(I18n.t("hints.risks.write_blocked.apply_mode_unset.action", env: unset.qualified_name))
    end

    it "sends a registry env with no apply mode to config/connections.yml, with no link it could not use" do
      unset = create(:kong_connection, admin_url: "https://kong-unset.test", apply_mode: nil)
      unset.project_env.update_columns(source: "registry")
      sign_in_to(unset)

      get entities_path(type: "upstream")
      notice = page.at_css("main .write-blocked")
      expect(notice.text.squish).to include(I18n.t("hints.risks.write_blocked.apply_mode_unset.body_registry"))
      expect(notice.text).not_to include("Direct apply")
      expect(notice.css("a")).to be_empty
    end

    it "says a read-only credential on a direct env is why, with its own words" do
      ro = create(:kong_connection, admin_url: "https://kong-ro.test", apply_mode: "direct")
      sign_in_to(ro, access: :ro)

      get entities_path(type: "upstream")
      expect(offered_controls).to be_empty
      expect(notices.text.squish).to include(I18n.t("hints.risks.write_blocked.read_only.title", env: ro.qualified_name))
      expect(page.at_css("main .write-blocked a[href='#{login_connection_path(ro)}']")).to be_present
    end

    it "keeps every one of them, and no notice, where the env can be written" do
      sign_in
      seen = visit_write_pages(connection)

      expect(seen.values.flat_map { |v| v[:controls] }.uniq).to match_array(
        [ "New upstream", "New global plugin", "New certificate", "New CA certificate", "Edit", "Delete", "Add target", "Apply" ]
      )
      expect(seen.values.flat_map { |v| v[:notices] }).to be_empty
    end
  end
end
