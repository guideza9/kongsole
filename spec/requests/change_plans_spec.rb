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

  it "shows decK's own message instead of a 500 when deck rejects the rendered YAML, scrubbed of any key" do
    sign_in
    plan = create(:change_plan, kong_connection: connection)
    allow_any_instance_of(Kong::ChangeApplier).to receive(:call)
      .and_raise(Kong::DeckCli::Error, "deck file validate failed: routes.0: name is required\n-----BEGIN PRIVATE KEY-----\nAAAA\n-----END PRIVATE KEY-----")

    post apply_change_plan_path(plan)

    expect(response).to redirect_to(change_plan_path(plan))
    expect(flash[:alert]).to include("name is required")
    expect(flash[:alert]).not_to include("AAAA")
  end

  it "shows a git failure the same way" do
    sign_in
    plan = create(:change_plan, kong_connection: connection)
    allow_any_instance_of(Kong::ChangeApplier).to receive(:call).and_raise(Kong::GitClient::Error, "git push failed: remote rejected")

    post apply_change_plan_path(plan)

    expect(response).to redirect_to(change_plan_path(plan))
    expect(flash[:alert]).to include("git push failed")
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
      expect(response.body).to include("Pushed to branch")
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
