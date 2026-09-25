require "rails_helper"
require "open3"
require "tmpdir"
require Rails.root.join("spec/support/pem_fixtures")

RSpec.describe "ChangePlans (web)", type: :request do
  let(:connection) { create(:kong_connection, admin_url: "https://kong-admin.test", credential_mode: "session") }

  def sign_in(conn = connection, username: "alice")
    base = conn.admin_url
    stub_request(:get, "#{base}/")
      .to_return(status: 200, body: { version: "3.7.0" }.to_json)
    stub_request(:patch, "#{base}#{Kong::AccessProbe::PROBE_PATH}")
      .to_return(status: 404, body: { message: "Not found" }.to_json)
    stub_request(:get, "#{base}/consumers/#{username}")
      .to_return(status: 200, body: { tags: [] }.to_json)
    stub_request(:get, "#{base}/routes")
      .to_return(status: 200, body: { data: [], offset: nil }.to_json)
    post login_connection_path(conn), params: { username: username, password: "pw" }
  end

  it "shows the diff for a pending plan" do
    sign_in
    plan = create(:change_plan, kong_connection: connection)

    get change_plan_path(plan)

    expect(response).to have_http_status(:ok)
    expect(response.body).to include("tags")
  end

  it "lays the review out as a summary strip, a real diff table, collapsed raw JSON and a sticky action bar" do
    sign_in
    plan = create(:change_plan, kong_connection: connection)

    get change_plan_path(plan)

    body = response.body
    expect(body).to include('class="plan-summary"')
    expect(body).to include("1 field changed").and include("All clear").and include("Direct apply")
    expect(body).to match(%r{<table class="diff-table diff-table--compare">.*<th scope="col">From</th>.*<th scope="row" class="font-mono">tags</th>}m)
    expect(body).to match(/<details class="disclosure">\s*<summary>Raw JSON/)
    expect(body).not_to match(/<details[^>]*\sopen/)
    expect(body).to include('class="action-bar ').and include('id="apply-plan-form"')
  end

  it "counts the outstanding gates at rank >= 2 and keeps the retype field inside the action bar" do
    prod = create(:kong_connection, :prod, name: "prod", admin_url: "https://kong-prod.test", credential_mode: "session", apply_mode: "pr")
    sign_in(prod)
    plan = create(:change_plan, kong_connection: prod, apply_mode: "pr")

    get change_plan_path(plan)

    expect(response.body).to include("2 to confirm")
    expect(response.body).to match(/class="plan-summary__cell env-strip env-prod"/)
    expect(response.body).to match(/<form[^>]*action-bar env-prod.*name="confirm_env_name".*<\/form>/m)
  end

  it "drops the guardrail count and the countdown once a plan is applied" do
    sign_in
    plan = create(:change_plan, kong_connection: connection, status: "applied")

    get change_plan_path(plan)

    expect(response.body).not_to include(">Guardrails<")
    expect(response.body).to include("Expiry no longer applies")
    expect(response.body).not_to include("action-bar")
  end

  it "warns about dependent routes when proposing to delete a service that still has them" do
    sign_in
    service_id = "88888888-8888-8888-8888-888888888888"
    create(:kong_entity, kong_connection: connection, entity_type: "route", name: "charge", parent_type: "service", parent_kong_id: service_id)
    plan = create(:change_plan, :delete, kong_connection: connection, entity_type: "service", target_kong_id: service_id,
      before: { "id" => service_id, "name" => "payments-api", "tags" => [] })

    get change_plan_path(plan)

    expect(response.body).to include("removed first")
    expect(response.body).to include("charge")
  end

  it "applies an update and redirects to the entity" do
    sign_in
    kong_id = "66666666-6666-6666-6666-666666666666"
    entity = create(:kong_entity, kong_connection: connection, kong_id: kong_id, name: "payments-api")
    plan = create(:change_plan, kong_connection: connection, target_kong_id: kong_id,
      before: { "id" => kong_id, "name" => "payments-api", "tags" => [ "payment" ], "updated_at" => 1_700_000_000 },
      after: { "id" => kong_id, "name" => "payments-api", "tags" => %w[payment deprecated], "updated_at" => 1_700_000_000 },
      base_updated_at: Time.zone.at(1_700_000_000))
    stub_request(:get, "https://kong-admin.test/services/#{kong_id}")
      .to_return(status: 200, body: { id: kong_id, name: "payments-api", tags: [ "payment" ], updated_at: 1_700_000_000 }.to_json)
    stub_request(:patch, "https://kong-admin.test/services/#{kong_id}")
      .to_return(status: 200, body: { id: kong_id, name: "payments-api", tags: %w[payment deprecated], updated_at: 1_700_000_500 }.to_json)

    post apply_change_plan_path(plan)

    expect(response).to redirect_to(entity_path(entity))
    expect(plan.reload.status).to eq("applied")
    expect(AuditEvent.last.actor_username).to eq("alice")

    get change_plan_path(plan)
    expect(response.body).to include("Applied")
    expect(response.body).not_to include(">Apply<")
  end

  describe "upstreams and targets (M5a)" do
    let(:upstream_id) { "aaaaaaaa-0000-0000-0000-00000000000a" }
    let(:target_id) { "cccccccc-0000-0000-0000-00000000000c" }

    it "titles a target plan by its host:port, since a target has no name" do
      sign_in
      plan = create(:change_plan, kong_connection: connection, entity_type: "target", operation: "create", target_kong_id: nil,
        parent_kong_id: upstream_id, before: {}, after: { "target" => "10.0.0.1:8080", "weight" => 100 }, diff: { "operation" => "create" })

      get change_plan_path(plan)

      expect(response.body).to include("Create 10.0.0.1:8080")
    end

    it "asks for a protected target's host:port on delete, not a blank name" do
      sign_in
      plan = create(:change_plan, :delete, kong_connection: connection, entity_type: "target", target_kong_id: target_id,
        parent_kong_id: upstream_id, before: { "id" => target_id, "target" => "10.0.0.1:8080", "tags" => [ "protected" ] })

      get change_plan_path(plan)

      expect(response.body).to include("Type <span class=\"font-mono\">10.0.0.1:8080</span>")
    end

    it "warns that deleting an upstream also removes its targets" do
      sign_in
      create(:kong_entity, kong_connection: connection, entity_type: "target", name: "10.0.0.1:8080",
        parent_type: "upstream", parent_kong_id: upstream_id)
      create(:kong_entity, kong_connection: connection, entity_type: "target", name: "10.0.0.2:8080",
        parent_type: "upstream", parent_kong_id: upstream_id)
      plan = create(:change_plan, :delete, kong_connection: connection, entity_type: "upstream", target_kong_id: upstream_id,
        before: { "id" => upstream_id, "name" => "orders", "tags" => [] })

      get change_plan_path(plan)

      expect(response.body).to include("also removes its 2 targets")
      expect(response.body).to include("10.0.0.1:8080")
    end

    it "shows no such warning when an upstream has no targets" do
      sign_in
      plan = create(:change_plan, :delete, kong_connection: connection, entity_type: "upstream", target_kong_id: upstream_id,
        before: { "id" => upstream_id, "name" => "orders", "tags" => [] })

      get change_plan_path(plan)

      expect(response.body).not_to include("also removes")
    end

    it "lands on the upstream's page after a target is created, not the generic list" do
      sign_in
      upstream = create(:kong_entity, kong_connection: connection, entity_type: "upstream", kong_id: upstream_id, name: "orders")
      plan = create(:change_plan, kong_connection: connection, entity_type: "target", operation: "create", target_kong_id: nil,
        parent_kong_id: upstream_id, before: {}, after: { "target" => "10.0.0.1:8080" }, diff: { "operation" => "create" }, base_updated_at: nil)
      stub_request(:post, "https://kong-admin.test/upstreams/#{upstream_id}/targets")
        .to_return(status: 201, body: { id: target_id, target: "10.0.0.1:8080", upstream: { id: upstream_id }, updated_at: 1_700_000_000 }.to_json)

      post apply_change_plan_path(plan)

      expect(response).to redirect_to(entity_path(upstream))
      expect(plan.reload.status).to eq("applied")
    end

    it "labels a deleted target by host:port in the flash message" do
      sign_in
      create(:kong_entity, kong_connection: connection, entity_type: "target", kong_id: target_id, name: "10.0.0.1:8080",
        parent_type: "upstream", parent_kong_id: upstream_id)
      plan = create(:change_plan, :delete, kong_connection: connection, entity_type: "target", target_kong_id: target_id,
        parent_kong_id: upstream_id, before: { "id" => target_id, "target" => "10.0.0.1:8080", "updated_at" => 1_700_000_000 })
      member = "https://kong-admin.test/upstreams/#{upstream_id}/targets/#{target_id}"
      stub_request(:get, member).to_return(status: 200, body: { id: target_id, target: "10.0.0.1:8080", updated_at: 1_700_000_000 }.to_json)
      stub_request(:delete, member).to_return(status: 204)

      post apply_change_plan_path(plan)

      expect(flash[:notice]).to eq("Deleted 10.0.0.1:8080.")
    end
  end

  it "lands back on the plan without a second red banner when decK rejects the rendered YAML" do
    sign_in
    plan = create(:change_plan, kong_connection: connection)
    allow_any_instance_of(Kong::ChangeApplier).to receive(:call)
      .and_raise(Kong::DeckCli::Error, "deck file validate failed: routes.0: name is required")

    post apply_change_plan_path(plan)

    expect(response).to redirect_to(change_plan_path(plan))
    # The applier stores the reason and the failed banner states it, so a flash
    # here would stack a duplicate red banner directly above that one.
    expect(flash[:alert]).to be_nil
  end

  it "lands back on the plan the same way for a git failure" do
    sign_in
    plan = create(:change_plan, kong_connection: connection)
    allow_any_instance_of(Kong::ChangeApplier).to receive(:call).and_raise(Kong::GitClient::Error, "git push failed: remote rejected")

    post apply_change_plan_path(plan)

    expect(response).to redirect_to(change_plan_path(plan))
    expect(flash[:alert]).to be_nil
  end

  it "shows the stored failure reason on a failed plan, so it outlives the redirect that produced it" do
    sign_in
    plan = create(:change_plan, kong_connection: connection, status: "failed",
      failure_reason: "deck file validate failed: routes.0: name is required")

    get change_plan_path(plan)

    expect(response.body).to match(%r{Failed\s*<time[^>]*>[^<]+</time>\s*&mdash; the change did not complete})
    expect(response.body).to include("routes.0: name is required")
  end

  it "still surfaces a guardrail refusal as a flash, since that leaves the plan pending with nothing to show" do
    sign_in
    plan = create(:change_plan, kong_connection: connection)
    allow_any_instance_of(Kong::ChangeApplier).to receive(:call)
      .and_raise(Kong::ChangeGuardrails::Violation, "this plan expired -- re-propose the change")

    post apply_change_plan_path(plan)

    expect(flash[:alert]).to include("re-propose the change")
    expect(plan.reload.status).to eq("pending")
  end

  it "rejects deleting an admin-path entity without the typed confirmation" do
    sign_in
    kong_id = "77777777-7777-7777-7777-777777777777"
    plan = create(:change_plan, :delete, kong_connection: connection, target_kong_id: kong_id,
      before: { "id" => kong_id, "name" => "admin-api", "tags" => [] })
    connection.update!(admin_path_fingerprint: { "service_id" => kong_id })

    post apply_change_plan_path(plan)

    expect(response).to redirect_to(change_plan_path(plan))
    follow_redirect!
    expect(response.body).to include("requires typing")
    expect(plan.reload.status).to eq("pending")
  end

  it "applies an admin-path delete when the typed confirmation matches" do
    sign_in
    kong_id = "88888888-8888-8888-8888-888888888888"
    plan = create(:change_plan, :delete, kong_connection: connection, target_kong_id: kong_id,
      before: { "id" => kong_id, "name" => "admin-api", "tags" => [], "updated_at" => 1_700_000_000 })
    connection.update!(admin_path_fingerprint: { "service_id" => kong_id })
    stub_request(:get, "https://kong-admin.test/services/#{kong_id}")
      .to_return(status: 200, body: { id: kong_id, name: "admin-api", updated_at: 1_700_000_000 }.to_json)
    stub_request(:delete, "https://kong-admin.test/services/#{kong_id}").to_return(status: 204)

    post apply_change_plan_path(plan), params: { confirmation_name: "admin-api" }

    expect(plan.reload.status).to eq("applied")
  end

  it "requires a correct password re-entry to apply on a rank >= 2 connection" do
    high_rank = create(:kong_connection, name: "uat-direct", env: "uat", rank: 2,
      admin_url: "https://kong-uat.test", credential_mode: "session")
    sign_in(high_rank)
    kong_id = "99999999-9999-9999-9999-999999999999"
    plan = create(:change_plan, kong_connection: high_rank, target_kong_id: kong_id,
      before: { "id" => kong_id, "name" => "svc", "updated_at" => 1_700_000_000 },
      after: { "id" => kong_id, "name" => "svc", "tags" => [ "x" ], "updated_at" => 1_700_000_000 },
      base_updated_at: Time.zone.at(1_700_000_000))

    post apply_change_plan_path(plan), params: { confirm_env_name: "uat-direct" }
    expect(response).to redirect_to(change_plan_path(plan))
    expect(plan.reload.status).to eq("pending")

    stub_request(:get, "https://kong-uat.test/").with(basic_auth: [ "alice", "correct" ])
      .to_return(status: 200, body: { version: "3.7.0" }.to_json)
    stub_request(:get, "https://kong-uat.test/services/#{kong_id}")
      .to_return(status: 200, body: { id: kong_id, name: "svc", updated_at: 1_700_000_000 }.to_json)
    stub_request(:patch, "https://kong-uat.test/services/#{kong_id}")
      .to_return(status: 200, body: { id: kong_id, name: "svc", tags: [ "x" ], updated_at: 1_700_000_500 }.to_json)

    post apply_change_plan_path(plan), params: { password: "correct", confirm_env_name: "UAT-Direct/UAT" }
    expect(plan.reload.status).to eq("applied")
  end

  describe "environment chrome (rank >= 2)" do
    let(:prod) do
      create(:kong_connection, :prod, name: "prod", admin_url: "https://kong-prod.test", credential_mode: "session", apply_mode: "pr")
    end
    let(:kong_id) { "77777777-7777-7777-7777-777777777777" }
    let(:plan) do
      create(:change_plan, kong_connection: prod, apply_mode: "pr", target_kong_id: kong_id,
        before: { "id" => kong_id, "name" => "svc", "updated_at" => 1_700_000_000 },
        after: { "id" => kong_id, "name" => "svc", "tags" => [ "x" ], "updated_at" => 1_700_000_000 })
    end

    it "marks the topbar and opens the plan with a PR-mode strip naming the branch" do
      sign_in(prod)

      get change_plan_path(plan)

      expect(response.body).to include("topbar env-prod")
      expect(response.body).to include("env-strip")
      expect(response.body).to include("PR mode")
      expect(response.body).to include("kongctl/#{plan.id}")
      expect(response.body).to include("nothing in Production changes yet")
      expect(response.body).to include('name="confirm_env_name"')
      expect(response.body).to include("btn-env")
      expect(response.body).not_to include("btn-danger")
    end

    it "uses true danger red only for a direct-mode live write" do
      sign_in(prod)
      plan.update!(apply_mode: "direct")

      get change_plan_path(plan)

      expect(response.body).to include("live write to Kong")
      expect(response.body).to include("This writes to Production now.")
      expect(response.body).to include("btn-danger")
    end

    it "states the operation, entity and environment in words in the action bar, and why the button is locked" do
      sign_in(prod)

      get change_plan_path(plan)

      bar = response.body[/<form[^>]*action-bar.*<\/form>/m]
      expect(bar).to include("Update service svc")
      expect(bar).to include("Production")
      expect(bar).to include("pushes a branch")
      expect(bar).to include("Type the connection name")
      expect(bar).to include("Push branch unlocks when the name matches")
      expect(bar).to include('aria-describedby="unlock-hint"')
      # The summary is the first child of the bar, ahead of the fields, so it
      # leads whether or not there are gates.
      expect(bar.index("action-bar__what")).to be < bar.index("action-bar__fields")
      expect(bar.index("action-bar__fields")).to be < bar.index("action-bar__buttons")
      expect(bar).to include("action-bar__actions")
    end

    it "says a direct apply writes to Kong now, in the bar" do
      sign_in(prod)
      plan.update!(apply_mode: "direct")

      get change_plan_path(plan)

      expect(response.body[/<form[^>]*action-bar.*<\/form>/m]).to include("writes to Kong now").and include("Apply unlocks when the name matches")
    end

    it "still names the change in the bar at rank 0-1, where nothing is typed" do
      sign_in
      plan = create(:change_plan, kong_connection: connection)

      get change_plan_path(plan)

      bar = response.body[/<form[^>]*action-bar.*<\/form>/m]
      expect(bar).to include("Development")
      expect(bar).not_to include("unlocks when")
    end

    describe "deleting at rank >= 2" do
      let(:delete_plan) do
        create(:change_plan, :delete, kong_connection: prod, apply_mode: "direct", target_kong_id: kong_id,
          before: { "id" => kong_id, "name" => "checkout-api", "tags" => [], "updated_at" => 1_700_000_000 })
      end

      it "asks for the entity's own name as well as the connection's, and names both in the hint" do
        sign_in(prod)

        get change_plan_path(delete_plan)

        expect(response.body).to include('name="confirmation_name"')
        expect(response.body).to include("to confirm deleting it from Production")
        expect(response.body).to include("Apply unlocks when both names match")
        expect(response.body).to include("Retype checkout-api")
      end

      it "refuses to apply the delete without the entity name" do
        sign_in(prod)

        post apply_change_plan_path(delete_plan), params: { password: "correct", confirm_env_name: "prod/prod" }

        expect(response).to redirect_to(change_plan_path(delete_plan))
        expect(flash[:alert]).to include("requires typing")
        expect(delete_plan.reload.status).to eq("pending")
      end

      it "keeps the admin-path wording for a protected entity" do
        sign_in(prod)
        prod.update!(admin_path_fingerprint: { "service_id" => kong_id })

        get change_plan_path(delete_plan)

        expect(response.body).to include("This is protected. Type")
        expect(response.body).not_to include("to confirm deleting it from")
      end
    end

    it "refuses to apply until the environment name is retyped" do
      sign_in(prod)

      post apply_change_plan_path(plan), params: { password: "correct", confirm_env_name: "produ" }

      expect(response).to redirect_to(change_plan_path(plan))
      expect(flash[:alert]).to include("Connection name didn't match")
      expect(plan.reload.status).to eq("pending")
    end

    it "tints the login page's topbar too, before any session exists" do
      get login_connection_path(prod)

      expect(response.body).to include("topbar env-prod")
      expect(response.body).to include("env-notice")
    end

    it "keeps rank 0-1 quiet: no rule, no strip, no retype, plain primary button" do
      sign_in
      plan = create(:change_plan, kong_connection: connection)

      get change_plan_path(plan)

      expect(response.body).not_to include("env-prod")
      expect(response.body).not_to include("env-uat")
      expect(response.body).not_to include("confirm_env_name")
      expect(response.body).to include("btn-primary")
    end
  end

  it "links Pending PRs from the primary nav, current on the list and not on a review page" do
    sign_in
    plan = create(:change_plan, kong_connection: connection, apply_mode: "pr", before: { "name" => "svc" }, after: { "name" => "svc" })

    get change_plans_path
    nav = Nokogiri::HTML(response.body).css("nav[aria-label='Primary'] a")
    expect(nav.map { |a| a.text.strip }).to include("Pending PRs")
    expect(nav.select { |a| a["aria-current"] }.map { |a| a.text.strip }).to eq([ "Pending PRs" ])

    get change_plan_path(plan)
    nav = Nokogiri::HTML(response.body).css("nav[aria-label='Primary'] a")
    expect(nav.select { |a| a["aria-current"] }.map { |a| a.text.strip }).to eq([ "Entities" ])
  end

  it "shows a plan's status as a badge and its time as the shared local timestamp on the list" do
    sign_in
    create(:change_plan, kong_connection: connection, apply_mode: "pr", status: "applied", before: { "name" => "svc" }, after: { "name" => "svc" })

    get change_plans_path

    doc = Nokogiri::HTML(response.body)
    expect(doc.at_css("td .chip.chip-ok").text).to include("Applied")
    expect(doc.css("tbody time[data-controller='local-time']").size).to eq(1)
  end

  it "tags an agent's plan as via agent on the list and the review page, and not a human's" do
    sign_in
    agent = create(:change_plan, kong_connection: connection, apply_mode: "pr", actor_kind: "agent", actor_username: "alice",
      before: { "name" => "agent-svc" }, after: { "name" => "agent-svc" })
    human = create(:change_plan, kong_connection: connection, apply_mode: "pr", actor_kind: "human", actor_username: "bob",
      before: { "name" => "human-svc" }, after: { "name" => "human-svc" })

    get change_plans_path
    rows = Nokogiri::HTML(response.body).css("tbody tr")
    expect(rows.find { |r| r.text.include?("agent-svc") }.css(".tag").map { |t| t.text.strip }).to include("via agent")
    expect(rows.find { |r| r.text.include?("human-svc") }.text).not_to include("via agent")

    byline = -> { Nokogiri::HTML(response.body).css("p").find { |p| p.text.include?("Proposed by") }.text }

    get change_plan_path(agent)
    expect(byline.call).to include("alice").and include("via agent")
    get change_plan_path(human)
    expect(byline.call).not_to include("via agent")
  end

  it "says a pushed plan's state in words and links its branch when the connection has a git URL" do
    sign_in
    set_env_policy(connection, git_web_url: "https://github.com/acme/kong-config/tree/{branch}")
    plan = create(:change_plan, kong_connection: connection, apply_mode: "pr", status: "applied", pr_state: "branch_pushed",
      commit_sha: "abcdef1234567890", before: { "name" => "svc" }, after: { "name" => "svc" })

    get change_plans_path

    body = response.body
    expect(body).to include("Branch pushed, awaiting PR")
    expect(body).not_to include(">branch_pushed<")
    link = Nokogiri::HTML(body).at_css("tbody a[href^='https://github.com/acme/kong-config/tree/']")
    expect(link.text).to include("kongctl/#{plan.id}")
    expect(link["rel"]).to eq("noopener")
    expect(body).to include("abcdef12")
  end

  it "shows the branch as plain text without a git URL, and nothing for a plan that never pushed" do
    sign_in
    plan = create(:change_plan, kong_connection: connection, apply_mode: "pr", status: "applied", pr_state: "branch_pushed",
      before: { "name" => "pushed-svc" }, after: { "name" => "pushed-svc" })
    create(:change_plan, kong_connection: connection, apply_mode: "pr", before: { "name" => "pending-svc" }, after: { "name" => "pending-svc" })

    get change_plans_path

    rows = Nokogiri::HTML(response.body).css("tbody tr")
    pushed = rows.find { |r| r.text.include?("pushed-svc") }
    expect(pushed.text).to include("kongctl/#{plan.id}")
    expect(pushed.css("td").last.at_css("a")).to be_nil
    expect(rows.find { |r| r.text.include?("pending-svc") }.css("td").last.text.strip).to eq("—")
  end

  describe "an applied plan's way on" do
    let(:service_id) { "aaaaaaaa-1111-1111-1111-aaaaaaaaaaaa" }

    it "offers the audit entry it left and the entity it changed" do
      sign_in
      entity = create(:kong_entity, kong_connection: connection, entity_type: "service", kong_id: service_id, name: "payments-api")
      plan = create(:change_plan, kong_connection: connection, status: "applied", target_kong_id: service_id)
      event = create(:audit_event, kong_connection: connection, change_plan: plan)

      get change_plan_path(plan)

      links = Nokogiri::HTML(response.body).css("a").to_h { |a| [ a.text.strip, a["href"] ] }
      expect(links["View audit entry"]).to eq(audit_events_path(anchor: "audit-event-#{event.id}"))
      expect(links["View service"]).to eq(entity_path(entity))
      expect(links).to include("Back to services")
    end

    it "offers no entity after a delete and no audit link when no event was recorded" do
      sign_in
      plan = create(:change_plan, :delete, kong_connection: connection, status: "applied", target_kong_id: service_id)

      get change_plan_path(plan)

      texts = Nokogiri::HTML(response.body).css("a").map { |a| a.text.strip }
      expect(texts).not_to include("View audit entry")
      expect(texts).not_to include("View service")
      expect(texts).to include("Back to services")
    end

    it "offers neither on a plan that is still pending" do
      sign_in
      plan = create(:change_plan, kong_connection: connection)

      get change_plan_path(plan)

      texts = Nokogiri::HTML(response.body).css("a").map { |a| a.text.strip }
      expect(texts).not_to include("View audit entry")
    end
  end

  it "lists only PR-mode plans for the current connection on the index page" do
    sign_in
    pr_plan = create(:change_plan, kong_connection: connection, apply_mode: "pr",
      before: { "name" => "payments-api" }, after: { "name" => "payments-api" })
    create(:change_plan, kong_connection: connection, apply_mode: "direct",
      before: { "name" => "orders-api" }, after: { "name" => "orders-api" })

    get change_plans_path

    expect(response).to have_http_status(:ok)
    expect(response.body).to include(pr_plan.before["name"])
  end

  describe "PR-mode apply" do
    def sh!(*cmd, chdir:)
      _out, err, status = Open3.capture3(*cmd, chdir: chdir.to_s)
      raise "#{cmd.join(' ')} failed: #{err}" unless status.success?
    end

    around do |example|
      Dir.mktmpdir do |dir|
        @tmp = Pathname.new(dir)
        example.run
      end
    end

    let(:bare_repo) { @tmp.join("uat.git") }
    let(:pr_connection) do
      create(:kong_connection, apply_mode: "pr", access_level: "ro", credential_mode: "session",
        admin_url: "https://kong-uat.test", git_repo: bare_repo.to_s, git_branch: "main", git_path: "kong.yaml",
        select_tags: [ "managed-by-kongctl" ])
    end

    before do
      sh!("git", "init", "--bare", "--initial-branch=main", bare_repo.to_s, chdir: @tmp)
      scratch = @tmp.join("seed")
      sh!("git", "clone", bare_repo.to_s, scratch.to_s, chdir: @tmp)
      File.write(scratch.join("kong.yaml"), Kong::DeckDocument.serialize(Kong::DeckDocument.parse(nil, select_tags: [ "managed-by-kongctl" ])))
      sh!("git", "add", "-A", chdir: scratch)
      sh!("git", "-c", "user.name=seed", "-c", "user.email=seed@example.com", "commit", "-m", "seed", chdir: scratch)
      sh!("git", "push", "origin", "main", chdir: scratch)

      original_new = Kong::GitClient.method(:new)
      allow(Kong::GitClient).to receive(:new) { |connection:| original_new.call(connection: connection, working_dir: @tmp.join("cache")) }
      allow(Kong::DeckCli).to receive(:validate).and_return(true)
      allow(Kong::DeckCli).to receive(:diff).and_return({ "changes" => [ { "name" => "orders-api", "change" => "create" } ] })
    end

    it "pushes a branch instead of writing to Kong, even on a read-only credential" do
      sign_in(pr_connection)
      plan = create(:change_plan, kong_connection: pr_connection, apply_mode: "pr", operation: "create",
        target_kong_id: nil, before: {}, after: { "name" => "orders-api" }, base_updated_at: nil)

      post apply_change_plan_path(plan)

      expect(plan.reload.status).to eq("applied")
      expect(plan.pr_state).to eq("branch_pushed")

      get change_plan_path(plan)
      expect(response.body).to match(%r{Pushed\s*<time[^>]*>[^<]+</time>\s*to branch})
    end
  end

  describe "certificates and SNIs (M5b)" do
    let(:cert_id) { "dddddddd-0000-0000-0000-00000000000d" }
    let(:sni_id) { "eeeeeeee-0000-0000-0000-00000000000e" }
    let(:ref) { "{vault://env/cert-pay-key}" }
    let(:fixture) { PemFixtures.self_signed(days: 60) }
    let(:created_cert) do
      { id: cert_id, cert: fixture[:cert_pem], key: ref, snis: [ "pay.example.internal" ], tags: [], updated_at: 1_700_000_000 }
    end

    def create_cert_plan
      create(:change_plan, kong_connection: connection, entity_type: "certificate", operation: "create", target_kong_id: nil,
        before: {}, after: { "cert" => fixture[:cert_pem], "key" => ref, "snis" => [ "pay.example.internal" ] },
        diff: { "operation" => "create" }, base_updated_at: nil)
    end

    it "asks the operator to confirm the env var Kong will read before applying a vault-referenced key" do
      sign_in

      get change_plan_path(create_cert_plan)

      expect(response.body).to include("CERT_PAY_KEY")
      expect(response.body).to include('name="acknowledge_env_vars"')
      expect(response.body).to include("Kong doesn").and include("check")
    end

    it "tells the operator CI resolves a decK placeholder, and asks for no acknowledgement" do
      sign_in
      plan = create(:change_plan, kong_connection: connection, apply_mode: "pr", entity_type: "certificate", operation: "create", target_kong_id: nil,
        before: {}, after: { "cert" => fixture[:cert_pem], "key" => %q(${{ env "DECK_CERT_PAY_KEY" }}) },
        diff: { "operation" => "create" }, base_updated_at: nil)

      get change_plan_path(plan)

      expect(response.body).to include("DECK_CERT_PAY_KEY", "CI environment", "ONE line", 'literal \n escapes', "shows the certificate")
      expect(response.body).not_to include("acknowledge_env_vars")
    end

    it "shows no decK note for a vault reference (that one asks for the acknowledgement instead), or for a direct-mode plan" do
      sign_in

      get change_plan_path(create_cert_plan)

      expect(response.body).not_to include("CI environment")
    end

    it "shows no such checkbox for an edit that leaves the key alone, or once applied" do
      sign_in
      tags_plan = create(:change_plan, kong_connection: connection, entity_type: "certificate", operation: "update", target_kong_id: cert_id,
        before: { "id" => cert_id, "key" => ref, "tags" => [] }, after: { "id" => cert_id, "key" => ref, "tags" => [ "core" ] },
        diff: { "tags" => { "from" => [], "to" => [ "core" ] } })
      applied = create_cert_plan.tap { |p| p.update!(status: "applied") }

      get change_plan_path(tags_plan)
      expect(response.body).not_to include("acknowledge_env_vars")
      get change_plan_path(applied)
      expect(response.body).not_to include("acknowledge_env_vars")
    end

    it "refuses to apply without the acknowledgement, says which variable, and touches nothing" do
      sign_in
      plan = create_cert_plan

      post apply_change_plan_path(plan)

      expect(response).to redirect_to(change_plan_path(plan))
      expect(flash[:alert]).to include("CERT_PAY_KEY")
      expect(plan.reload.status).to eq("pending")
      expect(WebMock).not_to have_requested(:post, "https://kong-admin.test/certificates")
    end

    it "applies once the box is ticked, and records the confirmation in the audit event" do
      sign_in
      plan = create_cert_plan
      post_cert = stub_request(:post, "https://kong-admin.test/certificates").to_return(status: 201, body: created_cert.to_json)

      post apply_change_plan_path(plan), params: { acknowledge_env_vars: "1" }

      expect(post_cert).to have_been_requested
      expect(plan.reload.status).to eq("applied")
      expect(AuditEvent.last.context).to eq({ "acknowledged_env_vars" => [ "CERT_PAY_KEY" ] })
    end

    it "lands on the certificate's page after an SNI is added, where the new SNI now shows" do
      sign_in
      certificate = create(:kong_entity, kong_connection: connection, entity_type: "certificate", kong_id: cert_id, name: "pay.example.internal")
      plan = create(:change_plan, kong_connection: connection, entity_type: "sni", operation: "create", target_kong_id: nil,
        parent_kong_id: cert_id, before: {}, after: { "name" => "api.example.internal", "certificate" => { "id" => cert_id } },
        diff: { "operation" => "create" }, base_updated_at: nil)
      stub_request(:post, "https://kong-admin.test/snis")
        .to_return(status: 201, body: { id: sni_id, name: "api.example.internal", certificate: { id: cert_id }, updated_at: 1_700_000_000 }.to_json)
      stub_request(:get, "https://kong-admin.test/certificates/#{cert_id}")
        .to_return(status: 200, body: created_cert.merge(snis: %w[api.example.internal pay.example.internal]).to_json)

      post apply_change_plan_path(plan)

      expect(response).to redirect_to(entity_path(certificate))
    end

    it "warns that deleting a certificate also removes its SNIs" do
      sign_in
      %w[a.example b.example].each do |host|
        create(:kong_entity, kong_connection: connection, entity_type: "sni", name: host, parent_type: "certificate", parent_kong_id: cert_id)
      end
      plan = create(:change_plan, :delete, kong_connection: connection, entity_type: "certificate", target_kong_id: cert_id,
        before: { "id" => cert_id, "snis" => %w[a.example b.example], "tags" => [] })

      get change_plan_path(plan)

      expect(response.body).to include("also removes its 2 SNIs").and include("a.example")
    end

    it "titles a certificate plan by its first SNI, and asks a protected one to be confirmed by that name" do
      sign_in
      plan = create(:change_plan, :delete, kong_connection: connection, entity_type: "certificate", target_kong_id: cert_id,
        before: { "id" => cert_id, "snis" => %w[b.example a.example], "tags" => [ "protected" ] })

      get change_plan_path(plan)

      expect(response.body).to include("Delete a.example")
      expect(response.body).to include("Type <span class=\"font-mono\">a.example</span>")
    end
  end
end
