require "rails_helper"
require "open3"
require "tmpdir"

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

    post apply_change_plan_path(plan)
    expect(response).to redirect_to(change_plan_path(plan))
    expect(plan.reload.status).to eq("pending")

    stub_request(:get, "https://kong-uat.test/").with(basic_auth: [ "alice", "correct" ])
      .to_return(status: 200, body: { version: "3.7.0" }.to_json)
    stub_request(:get, "https://kong-uat.test/services/#{kong_id}")
      .to_return(status: 200, body: { id: kong_id, name: "svc", updated_at: 1_700_000_000 }.to_json)
    stub_request(:patch, "https://kong-uat.test/services/#{kong_id}")
      .to_return(status: 200, body: { id: kong_id, name: "svc", tags: [ "x" ], updated_at: 1_700_000_500 }.to_json)

    post apply_change_plan_path(plan), params: { password: "correct" }
    expect(plan.reload.status).to eq("applied")
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
      File.write(scratch.join("kong.yaml"), Kong::DeckRenderer.serialize(Kong::DeckRenderer.parse(nil, select_tags: [ "managed-by-kongctl" ])))
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
      expect(response.body).to include("Pushed to branch")
    end
  end
end
