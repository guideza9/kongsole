require "rails_helper"
require "open3"
require "tmpdir"
require Rails.root.join("spec/support/pem_fixtures")

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
      File.write(scratch.join("kong.yaml"), Kong::DeckDocument.serialize(Kong::DeckDocument.parse(nil, select_tags: [ "managed-by-kongctl" ])))
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

    def seed!(text)
      dir = @tmp.join("reseed-#{SecureRandom.hex(4)}")
      sh!("git", "clone", bare_repo.to_s, dir.to_s, chdir: @tmp)
      File.write(dir.join("kong.yaml"), text)
      sh!("git", "add", "-A", chdir: dir)
      sh!("git", "-c", "user.name=seed", "-c", "user.email=seed@example.com", "commit", "-m", "reseed", chdir: dir)
      sh!("git", "push", "origin", "main", chdir: dir)
    end

    def tool_yaml(text)
      Kong::DeckDocument.serialize(Kong::DeckDocument.parse(text, select_tags: [ "managed-by-kongctl" ]))
    end

    def pushed_yaml(plan)
      out, = Open3.capture3("git", "show", "kongctl/#{plan.id}:kong.yaml", chdir: bare_repo.to_s)
      out
    end

    def branches
      Open3.capture3("git", "branch", "-a", chdir: bare_repo.to_s).first
    end

    def apply_pr(plan, **extra)
      described_class.new(change_plan: plan, client: pr_client, actor_username: "alice", secret: "pw", **extra).call
    end

    def pr_plan(entity_type:, operation: "create", after: {}, before: {}, target_kong_id: nil, parent_kong_id: nil)
      create(:change_plan, kong_connection: pr_connection, apply_mode: "pr", entity_type: entity_type, operation: operation,
        target_kong_id: target_kong_id, parent_kong_id: parent_kong_id, before: before, after: after, base_updated_at: nil)
    end

    it "renders a route nested under its service, found through the read-model" do
      service_id = "aaaaaaaa-0000-0000-0000-0000000000a1"
      create(:kong_entity, kong_connection: pr_connection, entity_type: "service", kong_id: service_id, name: "orders")
      seed!(tool_yaml("services:\n  - name: orders\n    url: http://orders:80\n"))
      plan = pr_plan(entity_type: "route", after: { "name" => "orders-route", "paths" => [ "/o" ], "service" => { "id" => service_id } })

      apply_pr(plan)

      expect(YAML.safe_load(pushed_yaml(plan))["services"][0]["routes"]).to eq([ { "name" => "orders-route", "paths" => [ "/o" ] } ])
      expect(plan.reload.status).to eq("applied")
    end

    it "renders an upstream, and a target nested under it" do
      upstream_id = "aaaaaaaa-0000-0000-0000-0000000000a2"
      create(:kong_entity, kong_connection: pr_connection, entity_type: "upstream", kong_id: upstream_id, name: "orders-up")
      seed!(tool_yaml("upstreams:\n  - name: orders-up\n"))
      plan = pr_plan(entity_type: "target", parent_kong_id: upstream_id, after: { "target" => "10.0.0.1:80", "weight" => 100 })

      apply_pr(plan)

      expect(YAML.safe_load(pushed_yaml(plan))["upstreams"][0]["targets"]).to eq([ { "target" => "10.0.0.1:80", "weight" => 100 } ])
    end

    it "mints the certificate id, persists it on the plan and records it in the audit event; a vault-referenced key still needs the acknowledgement" do
      pem = PemFixtures.self_signed(days: 60)[:cert_pem]
      plan = pr_plan(entity_type: "certificate", after: { "cert" => pem, "key" => "{vault://env/cert-pay-key}", "snis" => [ "pay.example.internal" ] })

      expect { apply_pr(plan) }.to raise_error(Kong::ChangeGuardrails::Violation, /CERT_PAY_KEY/)
      expect(plan.reload.status).to eq("pending")

      result = apply_pr(plan, env_acknowledged: true)

      minted = plan.reload.target_kong_id
      expect(minted).to match(/\A\h{8}-\h{4}-\h{4}-\h{4}-\h{12}\z/)
      expect(result.audit_event.target_kong_id).to eq(minted)
      expect(result.audit_event.context).to eq({ "acknowledged_env_vars" => [ "CERT_PAY_KEY" ] })
      certificate = YAML.safe_load(pushed_yaml(plan))["certificates"][0]
      expect(certificate).to include("id" => minted, "key" => "{vault://env/cert-pay-key}", "snis" => [ { "name" => "pay.example.internal" } ])
    end

    it "does not persist a freshly minted certificate id when a later step fails: the plan is failed with no target_kong_id" do
      pem = PemFixtures.self_signed(days: 60)[:cert_pem]
      allow(Kong::DeckCli).to receive(:validate).and_raise(Kong::DeckCli::Error, "deck file validate failed: boom")
      plan = pr_plan(entity_type: "certificate", after: { "cert" => pem, "key" => %q(${{ env "DECK_CERT_PAY_KEY" }}) })

      expect { apply_pr(plan) }.to raise_error(Kong::DeckCli::Error)

      expect(plan.target_kong_id).to be_nil
      expect(plan.reload.status).to eq("failed")
      expect(plan.target_kong_id).to be_nil
    end

    it "does not persist a minted certificate id when a refusal follows the render: the plan stays pending" do
      pem = PemFixtures.self_signed(days: 60)[:cert_pem]
      plan = pr_plan(entity_type: "certificate", after: { "cert" => pem, "key" => %q(${{ env "DECK_CERT_PAY_KEY" }}) })
      allow(Kong::DeckDocument).to receive(:serialize).and_raise(Kong::DeckDocument::Unparseable, "cannot reproduce")

      expect { apply_pr(plan) }.to raise_error(Kong::DeckDocument::Unparseable)

      expect(plan.reload.status).to eq("pending")
      expect(plan.target_kong_id).to be_nil
      expect(branches).not_to include("kongctl/#{plan.id}")
    end

    it "renders a decK placeholder single-quoted and asks for no acknowledgement: CI resolves the variable, not this tool" do
      pem = PemFixtures.self_signed(days: 60)[:cert_pem]
      plan = pr_plan(entity_type: "certificate", after: { "cert" => pem, "key" => %q(${{ env "DECK_CERT_PAY_KEY" }}) })

      apply_pr(plan)

      expect(pushed_yaml(plan)).to include(%q(key: '${{ env "DECK_CERT_PAY_KEY" }}'))
      expect(Kong::DeckCli).to have_received(:validate)
    end

    it "keeps what it does not manage: vaults, consumer_groups and flat routes survive an edit" do
      seed!(tool_yaml("vaults:\n  - name: env\n    prefix: env\nconsumer_groups:\n  - name: gold-tier\nroutes:\n  - name: flat-route\n"))
      plan = pr_plan(entity_type: "service", after: { "name" => "orders", "url" => "http://orders:80" })

      apply_pr(plan)

      out = pushed_yaml(plan)
      expect(out).to include("vaults:", "gold-tier", "flat-route", "name: orders")
    end

    it "refuses a config file it could not reproduce, before touching the repo: nothing pushed, plan still pending" do
      seed!("_format_version: '3.0'\n_info:\n  select_tags: [managed-by-kongctl]\nservices:\n  - {name: orders, url: 'http://orders:80'}\n")
      plan = pr_plan(entity_type: "service", after: { "name" => "billing" })

      expect { apply_pr(plan) }.to raise_error(Kong::DeckDocument::Unparseable, /would not survive a re-render/)

      expect(plan.reload.status).to eq("pending")
      expect(branches).not_to include("kongctl/#{plan.id}")
      expect(Kong::DeckCli).not_to have_received(:validate)
    end

    it "refuses a change it cannot render faithfully (an unnamed route), before touching the repo" do
      service_id = "aaaaaaaa-0000-0000-0000-0000000000a1"
      create(:kong_entity, kong_connection: pr_connection, entity_type: "service", kong_id: service_id, name: "orders")
      seed!(tool_yaml("services:\n  - name: orders\n"))
      plan = pr_plan(entity_type: "route", after: { "paths" => [ "/o" ], "service" => { "id" => service_id } })

      expect { apply_pr(plan) }.to raise_error(Kong::DeckRenderer::Unrenderable, /a route needs a name/)

      expect(plan.reload.status).to eq("pending")
      expect(branches).not_to include("kongctl/#{plan.id}")
    end

    it "raises the deliberate NotImplementedError for a credential before it even pulls the repo" do
      consumer_id = "aaaaaaaa-0000-0000-0000-0000000000a3"
      plan = pr_plan(entity_type: "keyauth_credential", parent_kong_id: consumer_id, after: { "key" => "x" })

      expect { apply_pr(plan) }.to raise_error(NotImplementedError, /keyauth_credential is deliberately never rendered/)

      expect(plan.reload.status).to eq("pending")
      expect(Kong::GitClient).not_to have_received(:new)
    end
  end

  describe "upstreams and targets (M5a)" do
    let(:upstream_id) { "aaaaaaaa-0000-0000-0000-00000000000a" }
    let(:target_id) { "cccccccc-0000-0000-0000-00000000000c" }
    let(:target_path) { "https://kong-admin.internal/upstreams/#{upstream_id}/targets/#{target_id}" }

    it "creates an upstream against /upstreams and writes it through to the read-model" do
      plan = create(:change_plan, kong_connection: connection, entity_type: "upstream", operation: "create",
        target_kong_id: nil, before: {}, after: { "name" => "orders", "algorithm" => "round-robin" }, base_updated_at: nil)
      post = stub_request(:post, "https://kong-admin.internal/upstreams")
        .with(body: { "name" => "orders", "algorithm" => "round-robin" })
        .to_return(status: 201, body: { id: upstream_id, name: "orders", algorithm: "round-robin", updated_at: 1_700_000_000 }.to_json)

      result = applier(plan).call

      expect(post).to have_been_requested
      expect(plan.reload.status).to eq("applied")
      expect(result.audit_event.entity_name).to eq("orders")
      upstream = KongEntity.find_by(kong_id: upstream_id, entity_type: "upstream")
      expect(upstream.logical_key).to eq("orders")
    end

    it "creates a target against the nested upstream path, using parent_kong_id" do
      create(:kong_entity, kong_connection: connection, entity_type: "upstream", kong_id: upstream_id, name: "orders")
      plan = create(:change_plan, kong_connection: connection, entity_type: "target", operation: "create",
        target_kong_id: nil, parent_kong_id: upstream_id, before: {}, after: { "target" => "10.0.0.1:8080", "weight" => 100 },
        base_updated_at: nil)
      post = stub_request(:post, "https://kong-admin.internal/upstreams/#{upstream_id}/targets")
        .with(body: { "target" => "10.0.0.1:8080", "weight" => 100 })
        .to_return(status: 201, body: { id: target_id, target: "10.0.0.1:8080", weight: 100, upstream: { id: upstream_id },
                                        updated_at: 1_700_000_000 }.to_json)

      result = applier(plan).call

      expect(post).to have_been_requested
      expect(plan.reload.status).to eq("applied")
      target = KongEntity.find_by(kong_id: target_id, entity_type: "target")
      expect(target.logical_key).to eq("orders/10.0.0.1:8080")
      expect(target.parent_kong_id).to eq(upstream_id)
      expect(result.audit_event.entity_name).to eq("10.0.0.1:8080")
    end

    it "updates a target through its nested member path, PATCHing only the changed fields" do
      create(:kong_entity, kong_connection: connection, entity_type: "upstream", kong_id: upstream_id, name: "orders")
      plan = create(:change_plan, kong_connection: connection, entity_type: "target", operation: "update",
        target_kong_id: target_id, parent_kong_id: upstream_id,
        before: { "id" => target_id, "target" => "10.0.0.1:8080", "weight" => 100, "updated_at" => 1_700_000_000 },
        after: { "id" => target_id, "target" => "10.0.0.1:8080", "weight" => 50, "updated_at" => 1_700_000_000 },
        diff: { "weight" => { "from" => 100, "to" => 50 } }, base_updated_at: Time.zone.at(1_700_000_000))
      get = stub_request(:get, target_path)
        .to_return(status: 200, body: { id: target_id, target: "10.0.0.1:8080", weight: 100, upstream: { id: upstream_id }, updated_at: 1_700_000_000 }.to_json)
      patch = stub_request(:patch, target_path).with(body: { "weight" => 50 })
        .to_return(status: 200, body: { id: target_id, target: "10.0.0.1:8080", weight: 50, upstream: { id: upstream_id }, updated_at: 1_700_000_500 }.to_json)

      result = applier(plan).call

      expect(get).to have_been_requested
      expect(patch).to have_been_requested
      expect(KongEntity.find_by(kong_id: target_id).data["weight"]).to eq(50)
      expect(result.audit_event.entity_name).to eq("10.0.0.1:8080")
    end

    # Kong reports a target's updated_at with millisecond fractions
    # (1789914728.226); every other entity uses whole seconds. The plan stores
    # it at database precision, so an exact == against a freshly parsed float
    # never matched -- every target update or delete was refused as "changed
    # by someone else". Found by running against a real Kong 3.7.
    it "applies a target update whose Kong updated_at carries millisecond fractions" do
      updated_at = 1_789_914_728.226
      plan = create(:change_plan, kong_connection: connection, entity_type: "target", operation: "update",
        target_kong_id: target_id, parent_kong_id: upstream_id,
        before: { "id" => target_id, "target" => "10.0.0.1:8080", "weight" => 100, "updated_at" => updated_at },
        after: { "id" => target_id, "target" => "10.0.0.1:8080", "weight" => 50, "updated_at" => updated_at },
        diff: { "weight" => { "from" => 100, "to" => 50 } }, base_updated_at: Time.zone.at(updated_at))
      plan = ChangePlan.find(plan.id) # as the applier sees it: read back from the database
      stub_request(:get, target_path)
        .to_return(status: 200, body: { id: target_id, target: "10.0.0.1:8080", weight: 100, upstream: { id: upstream_id }, updated_at: updated_at }.to_json)
      patch = stub_request(:patch, target_path)
        .to_return(status: 200, body: { id: target_id, target: "10.0.0.1:8080", weight: 50, upstream: { id: upstream_id }, updated_at: updated_at + 1 }.to_json)

      applier(plan).call

      expect(patch).to have_been_requested
      expect(plan.reload.status).to eq("applied")
    end

    it "applies a target delete whose Kong updated_at carries millisecond fractions" do
      updated_at = 1_789_914_728.226
      create(:kong_entity, kong_connection: connection, entity_type: "target", kong_id: target_id, name: "10.0.0.1:8080",
        parent_type: "upstream", parent_kong_id: upstream_id)
      plan = create(:change_plan, :delete, kong_connection: connection, entity_type: "target", target_kong_id: target_id,
        parent_kong_id: upstream_id, before: { "id" => target_id, "target" => "10.0.0.1:8080", "updated_at" => updated_at },
        base_updated_at: Time.zone.at(updated_at))
      plan = ChangePlan.find(plan.id)
      stub_request(:get, target_path)
        .to_return(status: 200, body: { id: target_id, target: "10.0.0.1:8080", updated_at: updated_at }.to_json)
      delete = stub_request(:delete, target_path).to_return(status: 204)

      applier(plan).call

      expect(delete).to have_been_requested
    end

    it "still refuses when the millisecond timestamp really did move" do
      plan = create(:change_plan, kong_connection: connection, entity_type: "target", operation: "update",
        target_kong_id: target_id, parent_kong_id: upstream_id,
        before: { "id" => target_id, "target" => "10.0.0.1:8080", "weight" => 100 },
        after: { "id" => target_id, "target" => "10.0.0.1:8080", "weight" => 50 },
        diff: { "weight" => { "from" => 100, "to" => 50 } }, base_updated_at: Time.zone.at(1_789_914_728.226))
      plan = ChangePlan.find(plan.id)
      stub_request(:get, target_path)
        .to_return(status: 200, body: { id: target_id, target: "10.0.0.1:8080", updated_at: 1_789_914_728.227 }.to_json)

      expect { applier(plan).call }.to raise_error(Kong::ChangeGuardrails::Violation, /changed by someone else/)
    end

    it "refuses to update a target someone else changed since the plan, checking through the nested path" do
      plan = create(:change_plan, kong_connection: connection, entity_type: "target", operation: "update",
        target_kong_id: target_id, parent_kong_id: upstream_id,
        before: { "id" => target_id, "target" => "10.0.0.1:8080", "weight" => 100 },
        after: { "id" => target_id, "target" => "10.0.0.1:8080", "weight" => 50 },
        diff: { "weight" => { "from" => 100, "to" => 50 } }, base_updated_at: Time.zone.at(1_700_000_000))
      stub_request(:get, target_path)
        .to_return(status: 200, body: { id: target_id, target: "10.0.0.1:8080", weight: 75, updated_at: 1_700_000_999 }.to_json)

      expect { applier(plan).call }.to raise_error(Kong::ChangeGuardrails::Violation, /changed by someone else/)
      expect(plan.reload.status).to eq("pending")
      expect(WebMock).not_to have_requested(:patch, target_path)
    end

    it "deletes a target through its nested member path and soft-deletes its read-model row" do
      create(:kong_entity, kong_connection: connection, entity_type: "target", kong_id: target_id,
        name: "10.0.0.1:8080", parent_type: "upstream", parent_kong_id: upstream_id)
      plan = create(:change_plan, :delete, kong_connection: connection, entity_type: "target", target_kong_id: target_id,
        parent_kong_id: upstream_id,
        before: { "id" => target_id, "target" => "10.0.0.1:8080", "weight" => 100, "updated_at" => 1_700_000_000 })
      stub_request(:get, target_path)
        .to_return(status: 200, body: { id: target_id, target: "10.0.0.1:8080", updated_at: 1_700_000_000 }.to_json)
      delete = stub_request(:delete, target_path).to_return(status: 204)

      result = applier(plan).call

      expect(delete).to have_been_requested
      expect(plan.reload.status).to eq("applied")
      expect(KongEntity.active.find_by(kong_id: target_id)).to be_nil
      expect(result.audit_event.entity_name).to eq("10.0.0.1:8080")
    end

    it "marks the plan failed when Kong rejects the target write (e.g. a duplicate target -> 409)" do
      plan = create(:change_plan, kong_connection: connection, entity_type: "target", operation: "create",
        target_kong_id: nil, parent_kong_id: upstream_id, before: {}, after: { "target" => "10.0.0.1:8080" }, base_updated_at: nil)
      stub_request(:post, "https://kong-admin.internal/upstreams/#{upstream_id}/targets")
        .to_return(status: 409, body: { name: "unique constraint violation" }.to_json)

      expect { applier(plan).call }.to raise_error(Kong::Client::UnexpectedResponse)
      expect(plan.reload.status).to eq("failed")
    end
  end

  describe "certificates and SNIs (M5b)" do
    let(:cert_id) { "dddddddd-0000-0000-0000-00000000000d" }
    let(:sni_id) { "eeeeeeee-0000-0000-0000-00000000000e" }
    let(:fixture) { PemFixtures.self_signed(days: 60) }
    let(:ref) { "{vault://env/cert-pay-key}" }
    let(:created_cert) do
      { id: cert_id, cert: fixture[:cert_pem], key: ref, snis: [ "pay.example.internal" ], tags: [], updated_at: 1_700_000_000 }
    end

    def cert_create_plan(after: nil)
      create(:change_plan, kong_connection: connection, entity_type: "certificate", operation: "create", target_kong_id: nil, before: {},
        after: after || { "cert" => fixture[:cert_pem], "key" => ref, "snis" => [ "pay.example.internal" ] },
        diff: { "operation" => "create" }, base_updated_at: nil)
    end

    describe "the env-var acknowledgement" do
      it "refuses a vault-referenced create until the variable is acknowledged, naming it, and touches nothing" do
        plan = cert_create_plan

        expect { applier(plan).call }.to raise_error(Kong::ChangeGuardrails::Violation, /CERT_PAY_KEY/)
        expect(plan.reload.status).to eq("pending")
        expect(WebMock).not_to have_requested(:any, /kong-admin/)
      end

      it "does not treat a raw param string as an acknowledgement" do
        expect { applier(cert_create_plan, env_acknowledged: "false").call }
          .to raise_error(Kong::ChangeGuardrails::Violation, /CERT_PAY_KEY/)
        expect(WebMock).not_to have_requested(:any, /kong-admin/)
      end

      it "applies once acknowledged, and records which variables were confirmed" do
        plan = cert_create_plan
        post = stub_request(:post, "https://kong-admin.internal/certificates")
          .with(body: hash_including("key" => ref)).to_return(status: 201, body: created_cert.to_json)

        result = applier(plan, env_acknowledged: true).call

        expect(post).to have_been_requested
        expect(plan.reload.status).to eq("applied")
        expect(result.audit_event.context).to eq({ "acknowledged_env_vars" => [ "CERT_PAY_KEY" ] })
        expect(result.audit_event.entity_name).to eq("pay.example.internal")
      end

      it "writes through metadata and the reference -- never the PEM -- to the read-model" do
        stub_request(:post, "https://kong-admin.internal/certificates").to_return(status: 201, body: created_cert.to_json)

        applier(cert_create_plan, env_acknowledged: true).call

        row = KongEntity.find_by(kong_id: cert_id)
        expect(row.data["key"]).to eq(ref)
        expect(row.data).not_to have_key("cert")
        expect(row.not_after).to be_within(5.seconds).of(60.days.from_now)
      end

      it "needs no acknowledgement for an edit that leaves the key alone" do
        plan = create(:change_plan, kong_connection: connection, entity_type: "certificate", operation: "update", target_kong_id: cert_id,
          before: { "id" => cert_id, "key" => ref, "tags" => [], "updated_at" => 1_700_000_000 },
          after: { "id" => cert_id, "key" => ref, "tags" => [ "core" ], "updated_at" => 1_700_000_000 },
          diff: { "tags" => { "from" => [], "to" => [ "core" ] } }, base_updated_at: Time.zone.at(1_700_000_000))
        stub_request(:get, "https://kong-admin.internal/certificates/#{cert_id}").to_return(status: 200, body: created_cert.to_json)
        patch = stub_request(:patch, "https://kong-admin.internal/certificates/#{cert_id}").with(body: { "tags" => [ "core" ] })
          .to_return(status: 200, body: created_cert.merge(tags: [ "core" ]).to_json)

        result = applier(plan).call

        expect(patch).to have_been_requested
        expect(result.audit_event.context).to eq({})
      end

      it "needs it when an update changes the key reference" do
        plan = create(:change_plan, kong_connection: connection, entity_type: "certificate", operation: "update", target_kong_id: cert_id,
          before: { "id" => cert_id, "key" => "{vault://env/cert-old-key}", "updated_at" => 1_700_000_000 },
          after: { "id" => cert_id, "key" => "{vault://env/cert-new-key}", "updated_at" => 1_700_000_000 },
          diff: { "key" => { "from" => "{vault://env/cert-old-key}", "to" => "{vault://env/cert-new-key}" } },
          base_updated_at: Time.zone.at(1_700_000_000))

        expect { applier(plan).call }.to raise_error(Kong::ChangeGuardrails::Violation, /CERT_NEW_KEY/)
      end

      it "needs none for a delete, and records an empty audit context" do
        plan = create(:change_plan, :delete, kong_connection: connection, entity_type: "certificate", target_kong_id: cert_id,
          before: { "id" => cert_id, "snis" => [ "pay.example.internal" ], "updated_at" => 1_700_000_000 })
        stub_request(:get, "https://kong-admin.internal/certificates/#{cert_id}").to_return(status: 200, body: created_cert.to_json)
        stub_request(:delete, "https://kong-admin.internal/certificates/#{cert_id}").to_return(status: 204)

        expect(applier(plan).call.audit_event.context).to eq({})
      end
    end

    describe "defense in depth on the key policy" do
      it "re-rejects a plan whose stored body carries a PEM, even when acknowledged, before any request" do
        plan = cert_create_plan(after: { "cert" => fixture[:cert_pem], "key" => fixture[:key_pem] })

        expect { applier(plan, env_acknowledged: true).call }.to raise_error(Kong::CertificateKeyPolicy::Rejected)
        expect(plan.reload.status).to eq("pending")
        expect(WebMock).not_to have_requested(:any, /kong-admin/)
      end

      it "re-rejects a decK placeholder when the connection is (now) direct" do
        plan = cert_create_plan(after: { "cert" => fixture[:cert_pem], "key" => '${{ env "DECK_CERT_A" }}' })

        expect { applier(plan, env_acknowledged: true).call }.to raise_error(Kong::CertificateKeyPolicy::Rejected, /direct/)
      end
    end

    describe "keeping the read-model honest" do
      before { create(:kong_entity, kong_connection: connection, entity_type: "certificate", kong_id: cert_id, name: "old.example") }

      it "refreshes the parent certificate after an SNI create, so its derived name follows" do
        plan = create(:change_plan, kong_connection: connection, entity_type: "sni", operation: "create", target_kong_id: nil,
          parent_kong_id: cert_id, before: {}, after: { "name" => "pay.example.internal", "certificate" => { "id" => cert_id } },
          diff: { "operation" => "create" }, base_updated_at: nil)
        stub_request(:post, "https://kong-admin.internal/snis").with(body: hash_including("certificate" => { "id" => cert_id }))
          .to_return(status: 201, body: { id: sni_id, name: "pay.example.internal", certificate: { id: cert_id }, updated_at: 1_700_000_000 }.to_json)
        refetch = stub_request(:get, "https://kong-admin.internal/certificates/#{cert_id}").to_return(status: 200, body: created_cert.to_json)

        applier(plan).call

        expect(refetch).to have_been_requested
        expect(KongEntity.find_by(kong_id: sni_id).parent_kong_id).to eq(cert_id)
        expect(KongEntity.find_by(kong_id: cert_id).name).to eq("pay.example.internal")
      end

      it "still applies and audits the SNI when the parent's refresh returns garbage -- the write already happened" do
        plan = create(:change_plan, kong_connection: connection, entity_type: "sni", operation: "create", target_kong_id: nil,
          parent_kong_id: cert_id, before: {}, after: { "name" => "pay.example.internal", "certificate" => { "id" => cert_id } },
          diff: { "operation" => "create" }, base_updated_at: nil)
        stub_request(:post, "https://kong-admin.internal/snis")
          .to_return(status: 201, body: { id: sni_id, name: "pay.example.internal", certificate: { id: cert_id }, updated_at: 1_700_000_000 }.to_json)
        stub_request(:get, "https://kong-admin.internal/certificates/#{cert_id}").to_return(status: 200, body: "<html>not json")

        result = applier(plan).call

        expect(plan.reload.status).to eq("applied")
        expect(result.audit_event).to be_persisted
      end

      it "still applies the SNI when refreshing the parent fails -- the write already happened" do
        plan = create(:change_plan, kong_connection: connection, entity_type: "sni", operation: "create", target_kong_id: nil,
          parent_kong_id: cert_id, before: {}, after: { "name" => "pay.example.internal", "certificate" => { "id" => cert_id } },
          diff: { "operation" => "create" }, base_updated_at: nil)
        stub_request(:post, "https://kong-admin.internal/snis")
          .to_return(status: 201, body: { id: sni_id, name: "pay.example.internal", certificate: { id: cert_id }, updated_at: 1_700_000_000 }.to_json)
        stub_request(:get, "https://kong-admin.internal/certificates/#{cert_id}").to_return(status: 503, body: "")

        applier(plan).call

        expect(plan.reload.status).to eq("applied")
        expect(KongEntity.find_by(kong_id: sni_id)).to be_present
      end

      it "refreshes both the old and the new certificate when an SNI update re-points it" do
        other_id = "ffffffff-0000-0000-0000-00000000000f"
        create(:kong_entity, kong_connection: connection, entity_type: "certificate", kong_id: other_id, name: "new.example")
        create(:kong_entity, kong_connection: connection, entity_type: "sni", kong_id: sni_id, name: "pay.example.internal",
          parent_type: "certificate", parent_kong_id: cert_id)
        plan = create(:change_plan, kong_connection: connection, entity_type: "sni", operation: "update", target_kong_id: sni_id,
          parent_kong_id: cert_id,
          before: { "id" => sni_id, "name" => "pay.example.internal", "certificate" => { "id" => cert_id }, "updated_at" => 1_700_000_000 },
          after: { "id" => sni_id, "name" => "pay.example.internal", "certificate" => { "id" => other_id }, "updated_at" => 1_700_000_000 },
          diff: { "certificate" => { "from" => { "id" => cert_id }, "to" => { "id" => other_id } } },
          base_updated_at: Time.zone.at(1_700_000_000))
        moved = { id: sni_id, name: "pay.example.internal", certificate: { id: other_id }, updated_at: 1_700_000_001 }
        stub_request(:get, "https://kong-admin.internal/snis/#{sni_id}")
          .to_return(status: 200, body: moved.merge(certificate: { id: cert_id }, updated_at: 1_700_000_000).to_json)
        stub_request(:patch, "https://kong-admin.internal/snis/#{sni_id}").to_return(status: 200, body: moved.to_json)
        old_refetch = stub_request(:get, "https://kong-admin.internal/certificates/#{cert_id}")
          .to_return(status: 200, body: created_cert.merge(snis: []).to_json)
        new_refetch = stub_request(:get, "https://kong-admin.internal/certificates/#{other_id}")
          .to_return(status: 200, body: created_cert.merge(id: other_id, snis: [ "pay.example.internal" ]).to_json)

        applier(plan).call

        expect(plan.reload.status).to eq("applied")
        expect(new_refetch).to have_been_requested
        expect(old_refetch).to have_been_requested
      end

      it "soft-deletes a deleted certificate's SNIs, which Kong removes with it" do
        create(:kong_entity, kong_connection: connection, entity_type: "sni", kong_id: sni_id, name: "pay.example.internal",
          parent_type: "certificate", parent_kong_id: cert_id)
        plan = create(:change_plan, :delete, kong_connection: connection, entity_type: "certificate", target_kong_id: cert_id,
          before: { "id" => cert_id, "updated_at" => 1_700_000_000 })
        stub_request(:get, "https://kong-admin.internal/certificates/#{cert_id}").to_return(status: 200, body: created_cert.to_json)
        stub_request(:delete, "https://kong-admin.internal/certificates/#{cert_id}").to_return(status: 204)

        applier(plan).call

        expect(KongEntity.active.where(kong_connection: connection, kong_id: [ cert_id, sni_id ])).to be_empty
      end

      it "does the same for an upstream's targets (closing an M5a gap: they stayed listed until the next sync)" do
        upstream_id = "aaaaaaaa-0000-0000-0000-00000000000a"
        target_id = "cccccccc-0000-0000-0000-00000000000c"
        create(:kong_entity, kong_connection: connection, entity_type: "upstream", kong_id: upstream_id, name: "orders")
        create(:kong_entity, kong_connection: connection, entity_type: "target", kong_id: target_id, name: "10.0.0.1:8080",
          parent_type: "upstream", parent_kong_id: upstream_id)
        plan = create(:change_plan, :delete, kong_connection: connection, entity_type: "upstream", target_kong_id: upstream_id,
          before: { "id" => upstream_id, "name" => "orders", "updated_at" => 1_700_000_000 })
        stub_request(:get, "https://kong-admin.internal/upstreams/#{upstream_id}")
          .to_return(status: 200, body: { id: upstream_id, name: "orders", updated_at: 1_700_000_000 }.to_json)
        stub_request(:delete, "https://kong-admin.internal/upstreams/#{upstream_id}").to_return(status: 204)

        applier(plan).call

        expect(KongEntity.active.where(kong_connection: connection, kong_id: [ upstream_id, target_id ])).to be_empty
      end
    end
  end
end
