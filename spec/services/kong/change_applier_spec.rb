require "rails_helper"
require "open3"
require "tmpdir"

RSpec.describe Kong::ChangeApplier do
  APPLIER_SVC_1 = "33333333-3333-3333-3333-333333333333"
  APPLIER_ADMIN_SVC = "bbbbbbbb-bbbb-bbbb-bbbb-bbbbbbbbbbbb"

  let(:connection) do
    create(:kong_connection, admin_url: "https://kong-admin.internal", auth_username: "kongctl",
      access_level: "rw", admin_path_fingerprint: { "service_id" => APPLIER_ADMIN_SVC })
  end
  let(:client) { Kong::Client.new(connection: connection, secret: "pw") }

  def applier(change_plan, **overrides)
    described_class.new(change_plan: change_plan, client: client, actor_username: "alice", **overrides)
  end

  describe "#call" do
    it "applies an update: writes to Kong, write-throughs kong_entities, and records an audit event" do
      plan = create(:change_plan, kong_connection: connection, operation: "update", target_kong_id: APPLIER_SVC_1,
        before: { "id" => APPLIER_SVC_1, "name" => "payments-api", "tags" => [ "payment" ], "updated_at" => 1_700_000_000 },
        after: { "id" => APPLIER_SVC_1, "name" => "payments-api", "tags" => %w[payment deprecated], "updated_at" => 1_700_000_000 },
        diff: { "tags" => { "from" => [ "payment" ], "to" => %w[payment deprecated] } },
        base_updated_at: Time.zone.at(1_700_000_000))

      stub_request(:get, "https://kong-admin.internal/services/#{APPLIER_SVC_1}")
        .to_return(status: 200, body: { id: APPLIER_SVC_1, name: "payments-api", tags: [ "payment" ], updated_at: 1_700_000_000 }.to_json)
      stub_request(:patch, "https://kong-admin.internal/services/#{APPLIER_SVC_1}")
        .to_return(status: 200, body: { id: APPLIER_SVC_1, name: "payments-api", tags: %w[payment deprecated], updated_at: 1_700_000_500 }.to_json)

      result = applier(plan).call

      expect(plan.reload.status).to eq("applied")
      expect(result.audit_event.actor_username).to eq("alice")
      expect(result.audit_event.diff).to eq(plan.diff)

      entity = KongEntity.find_by(kong_connection: connection, kong_id: APPLIER_SVC_1)
      expect(entity.tags).to eq(%w[payment deprecated])
    end

    # Echoing Kong's own GET payload back at it on a PATCH is both needless
    # and unsafe: a key-auth credential comes back carrying `ttl: null`,
    # which Kong 3.7 then 500s on when it is written back.
    it "PATCHes only the changed fields, not the whole merged document" do
      plan = create(:change_plan, kong_connection: connection, operation: "update", target_kong_id: APPLIER_SVC_1,
        before: { "id" => APPLIER_SVC_1, "name" => "payments-api", "port" => 80, "ttl" => nil, "updated_at" => 1_700_000_000 },
        after: { "id" => APPLIER_SVC_1, "name" => "payments-api", "port" => 8443, "ttl" => nil, "updated_at" => 1_700_000_000 },
        diff: { "port" => { "from" => 80, "to" => 8443 } },
        base_updated_at: Time.zone.at(1_700_000_000))

      stub_request(:get, "https://kong-admin.internal/services/#{APPLIER_SVC_1}")
        .to_return(status: 200, body: { id: APPLIER_SVC_1, name: "payments-api", updated_at: 1_700_000_000 }.to_json)
      patch_request = stub_request(:patch, "https://kong-admin.internal/services/#{APPLIER_SVC_1}")
        .with(body: { "port" => 8443 })
        .to_return(status: 200, body: { id: APPLIER_SVC_1, name: "payments-api", port: 8443, updated_at: 1_700_000_500 }.to_json)

      applier(plan).call

      expect(patch_request).to have_been_requested
    end

    it "applies a delete of a non-protected entity without a confirmation name" do
      plan = create(:change_plan, :delete, kong_connection: connection, target_kong_id: APPLIER_SVC_1,
        before: { "id" => APPLIER_SVC_1, "name" => "payments-webhook", "tags" => [], "updated_at" => 1_700_000_000 })
      create(:kong_entity, kong_connection: connection, kong_id: APPLIER_SVC_1, entity_type: "service", name: "payments-webhook")

      stub_request(:get, "https://kong-admin.internal/services/#{APPLIER_SVC_1}")
        .to_return(status: 200, body: { id: APPLIER_SVC_1, name: "payments-webhook", updated_at: 1_700_000_000 }.to_json)
      stub_request(:delete, "https://kong-admin.internal/services/#{APPLIER_SVC_1}").to_return(status: 204)

      applier(plan).call

      expect(plan.reload.status).to eq("applied")
      expect(KongEntity.active.find_by(kong_id: APPLIER_SVC_1)).to be_nil
    end

    it "rejects deleting an admin-path entity without the exact typed name" do
      plan = create(:change_plan, :delete, kong_connection: connection, target_kong_id: APPLIER_ADMIN_SVC,
        before: { "id" => APPLIER_ADMIN_SVC, "name" => "admin-api", "tags" => [] })

      expect {
        applier(plan, confirmation_name: "wrong-name").call
      }.to raise_error(Kong::ChangeGuardrails::Violation, /does not match/)
      expect(plan.reload.status).to eq("pending")
    end

    it "applies deleting an admin-path entity when the typed name matches exactly" do
      plan = create(:change_plan, :delete, kong_connection: connection, target_kong_id: APPLIER_ADMIN_SVC,
        before: { "id" => APPLIER_ADMIN_SVC, "name" => "admin-api", "tags" => [], "updated_at" => 1_700_000_000 })
      stub_request(:get, "https://kong-admin.internal/services/#{APPLIER_ADMIN_SVC}")
        .to_return(status: 200, body: { id: APPLIER_ADMIN_SVC, name: "admin-api", updated_at: 1_700_000_000 }.to_json)
      stub_request(:delete, "https://kong-admin.internal/services/#{APPLIER_ADMIN_SVC}").to_return(status: 204)

      applier(plan, confirmation_name: "admin-api").call

      expect(plan.reload.status).to eq("applied")
    end

    it "rejects applying an expired plan" do
      plan = create(:change_plan, :expired, kong_connection: connection, target_kong_id: APPLIER_SVC_1)

      expect { applier(plan).call }.to raise_error(Kong::ChangeGuardrails::Violation, /expired/)
      expect(plan.reload.status).to eq("pending")
    end

    it "rejects applying when the credential can no longer write" do
      plan = create(:change_plan, kong_connection: connection, target_kong_id: APPLIER_SVC_1)
      connection.update!(access_level: "ro")

      expect { applier(plan).call }.to raise_error(Kong::ChangeGuardrails::Violation, /can't write/)
    end

    it "rejects applying when the entity changed since the plan was proposed (optimistic lock)" do
      plan = create(:change_plan, kong_connection: connection, target_kong_id: APPLIER_SVC_1,
        base_updated_at: Time.zone.at(1_700_000_000))
      stub_request(:get, "https://kong-admin.internal/services/#{APPLIER_SVC_1}")
        .to_return(status: 200, body: { id: APPLIER_SVC_1, name: "payments-api", updated_at: 1_700_099_999 }.to_json)

      expect {
        applier(plan).call
      }.to raise_error(Kong::ChangeGuardrails::Violation, /changed by someone else/)
      expect(plan.reload.status).to eq("pending")
    end

    it "does not apply twice: a non-pending plan is rejected" do
      plan = create(:change_plan, kong_connection: connection, target_kong_id: APPLIER_SVC_1, status: "applied")

      expect { applier(plan).call }.to raise_error(Kong::ChangeGuardrails::Violation, /not pending/)
    end

    it "marks the plan failed when Kong rejects the write" do
      plan = create(:change_plan, kong_connection: connection, target_kong_id: APPLIER_SVC_1,
        before: { "id" => APPLIER_SVC_1, "name" => "payments-api", "updated_at" => 1_700_000_000 },
        base_updated_at: Time.zone.at(1_700_000_000))
      stub_request(:get, "https://kong-admin.internal/services/#{APPLIER_SVC_1}")
        .to_return(status: 200, body: { id: APPLIER_SVC_1, name: "payments-api", updated_at: 1_700_000_000 }.to_json)
      stub_request(:patch, "https://kong-admin.internal/services/#{APPLIER_SVC_1}")
        .to_return(status: 404, body: { message: "no Route matched with those values" }.to_json)

      expect { applier(plan).call }.to raise_error(Kong::Client::RouteNotMatched)
      expect(plan.reload.status).to eq("failed")
    end

    it "rejects applying an agent-authored delete of an admin-path entity even with a matching confirmation name (defense in depth -- this plan should never have been created)" do
      plan = create(:change_plan, :delete, kong_connection: connection, actor_kind: "agent", target_kong_id: APPLIER_ADMIN_SVC,
        before: { "id" => APPLIER_ADMIN_SVC, "name" => "admin-api", "tags" => [] })

      expect {
        applier(plan, confirmation_name: "admin-api").call
      }.to raise_error(Kong::ChangeGuardrails::Violation, /no override/)
      expect(plan.reload.status).to eq("pending")
    end

    it "creates a route against /routes and write-throughs it into kong_entities" do
      route_id = "dddddddd-dddd-dddd-dddd-dddddddddddd"
      plan = create(:change_plan, kong_connection: connection, entity_type: "route", operation: "create",
        target_kong_id: nil, before: {}, after: { "name" => "charge", "paths" => [ "/charge" ] }, base_updated_at: nil)
      stub_request(:post, "https://kong-admin.internal/routes")
        .to_return(status: 201, body: { id: route_id, name: "charge", paths: [ "/charge" ], updated_at: 1_700_000_000 }.to_json)

      result = applier(plan).call

      expect(plan.reload.status).to eq("applied")
      expect(result.audit_event.entity_type).to eq("route")
      expect(KongEntity.find_by(kong_id: route_id, entity_type: "route")).to be_present
    end

    it "creates a keyauth credential against the nested consumer create path, using parent_kong_id" do
      consumer_id = "cccccccc-cccc-cccc-cccc-cccccccccccc"
      cred_id = "eeeeeeee-eeee-eeee-eeee-eeeeeeeeeeee"
      plan = create(:change_plan, kong_connection: connection, entity_type: "keyauth_credential", operation: "create",
        target_kong_id: nil, parent_kong_id: consumer_id, before: {}, after: { "key" => "s3cr3t" }, base_updated_at: nil)
      stub_request(:post, "https://kong-admin.internal/consumers/#{consumer_id}/key-auth")
        .to_return(status: 201, body: { id: cred_id, key: "s3cr3t", consumer: { id: consumer_id }, updated_at: 1_700_000_000 }.to_json)

      applier(plan).call

      expect(plan.reload.status).to eq("applied")
      credential = KongEntity.find_by(kong_id: cred_id, entity_type: "keyauth_credential")
      expect(credential.data["key"]).to eq("[REDACTED]")
      expect(credential.parent_kong_id).to eq(consumer_id)
    end

    it "deletes a consumer against /consumers" do
      consumer_id = "cccccccc-cccc-cccc-cccc-cccccccccccc"
      create(:kong_entity, kong_connection: connection, kong_id: consumer_id, entity_type: "consumer", name: "alice")
      plan = create(:change_plan, :delete, kong_connection: connection, entity_type: "consumer", target_kong_id: consumer_id,
        before: { "id" => consumer_id, "username" => "alice", "updated_at" => 1_700_000_000 })
      stub_request(:get, "https://kong-admin.internal/consumers/#{consumer_id}")
        .to_return(status: 200, body: { id: consumer_id, username: "alice", updated_at: 1_700_000_000 }.to_json)
      stub_request(:delete, "https://kong-admin.internal/consumers/#{consumer_id}").to_return(status: 204)

      applier(plan).call

      expect(plan.reload.status).to eq("applied")
      expect(KongEntity.active.find_by(kong_id: consumer_id)).to be_nil
    end
  end

  describe "#call in PR mode" do
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

    before do
      sh!("git", "init", "--bare", "--initial-branch=main", bare_repo.to_s, chdir: @tmp)
      scratch = @tmp.join("seed")
      sh!("git", "clone", bare_repo.to_s, scratch.to_s, chdir: @tmp)
      File.write(scratch.join("kong.yaml"), Kong::DeckRenderer.serialize(Kong::DeckRenderer.parse(nil, select_tags: [ "managed-by-kongctl" ])))
      sh!("git", "add", "-A", chdir: scratch)
      sh!("git", "-c", "user.name=seed", "-c", "user.email=seed@example.com", "commit", "-m", "seed", chdir: scratch)
      sh!("git", "push", "origin", "main", chdir: scratch)
    end

    let(:pr_connection) do
      create(:kong_connection, apply_mode: "pr", access_level: "ro", admin_url: "https://kong-uat-admin-ro.internal",
        git_repo: bare_repo.to_s, git_branch: "main", git_path: "kong.yaml", select_tags: [ "managed-by-kongctl" ])
    end

    before do
      original_new = Kong::GitClient.method(:new)
      allow(Kong::GitClient).to receive(:new) { |connection:| original_new.call(connection: connection, working_dir: @tmp.join("cache")) }
      allow(Kong::DeckCli).to receive(:validate).and_return(true)
      allow(Kong::DeckCli).to receive(:diff).and_return({ "changes" => [ { "name" => "payments-api", "change" => "create" } ] })
    end

    def pr_client
      Kong::Client.new(connection: pr_connection, secret: "pw")
    end

    it "never writes to Kong; instead renders, validates, diffs, commits, and pushes a branch" do
      plan = create(:change_plan, kong_connection: pr_connection, apply_mode: "pr", operation: "create",
        target_kong_id: nil, before: {}, after: { "name" => "payments-api", "url" => "http://payments:8080" },
        base_updated_at: nil)

      result = described_class.new(change_plan: plan, client: pr_client, actor_username: "alice", secret: "pw").call

      expect(plan.reload.status).to eq("applied")
      expect(plan.pr_state).to eq("branch_pushed")
      expect(plan.commit_sha).to match(/\A[0-9a-f]{40}\z/)
      expect(plan.deck_diff).to eq({ "changes" => [ { "name" => "payments-api", "change" => "create" } ] })
      expect(result.audit_event.operation).to eq("create")

      branches, = Open3.capture3("git", "branch", "-a", chdir: bare_repo.to_s)
      expect(branches).to include("kongctl/#{plan.id}")

      main_yaml, = Open3.capture3("git", "show", "main:kong.yaml", chdir: bare_repo.to_s)
      expect(main_yaml).not_to include("payments-api")

      expect(Kong::DeckCli).to have_received(:diff).with(anything, connection: pr_connection, secret: "pw")
    end

    it "allows proposing/applying a PR-mode change even when the credential is read-only" do
      expect(pr_connection.access_level).to eq("ro")

      plan = create(:change_plan, kong_connection: pr_connection, apply_mode: "pr", operation: "create",
        target_kong_id: nil, before: {}, after: { "name" => "orders-api" }, base_updated_at: nil)

      expect {
        described_class.new(change_plan: plan, client: pr_client, actor_username: "alice", secret: "pw").call
      }.not_to raise_error
    end

    it "refuses to render an admin-path entity into decK YAML at all" do
      pr_connection.update!(admin_path_fingerprint: { "service_id" => APPLIER_ADMIN_SVC })
      plan = create(:change_plan, kong_connection: pr_connection, apply_mode: "pr", operation: "update",
        target_kong_id: APPLIER_ADMIN_SVC, before: { "id" => APPLIER_ADMIN_SVC, "name" => "admin-api" },
        after: { "id" => APPLIER_ADMIN_SVC, "name" => "admin-api", "tags" => [ "x" ] }, base_updated_at: nil)

      expect {
        described_class.new(change_plan: plan, client: pr_client, actor_username: "alice", secret: "pw").call
      }.to raise_error(Kong::ChangeGuardrails::Violation, /never rendered/)
      expect(plan.reload.status).to eq("pending")
      expect(Kong::GitClient).not_to have_received(:new)
    end

    it "raises a clear NotImplementedError for a PR-mode plan on any entity_type but service" do
      plan = create(:change_plan, kong_connection: pr_connection, apply_mode: "pr", entity_type: "route", operation: "create",
        target_kong_id: nil, before: {}, after: { "name" => "charge" }, base_updated_at: nil)

      expect {
        described_class.new(change_plan: plan, client: pr_client, actor_username: "alice", secret: "pw").call
      }.to raise_error(NotImplementedError, /not yet rendered/)
      expect(Kong::GitClient).not_to have_received(:new)
    end
  end
end
