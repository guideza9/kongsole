require "rails_helper"
require Rails.root.join("spec/support/bare_git_repo")
require Rails.root.join("spec/support/pem_fixtures")

# R8.6: a changeset leaves Kongsole as one gated branch with a PR body. Every
# refusal happens before the push, and leaves git, the changeset and its
# items as they were.
RSpec.describe Kong::ChangesetSubmitter do
  include BareGitRepo

  let(:repo) { bare_git_repo(path: "uat/kong.yaml", select_tags: %w[managed-by-kongctl]) }
  let(:project) { create(:project, git_repo: repo.to_s, git_branch: "main") }
  let(:env) { create(:project_env, project: project, name: "uat", apply_mode: "pr", source: "registry",
    git_path: "uat/kong.yaml", select_tags: %w[managed-by-kongctl]) }
  let(:connection) { create(:kong_connection, project_env: env, access_level: "ro") }
  let(:changeset) { create(:changeset, kong_connection: connection) }

  before do
    allow(Kong::DeckCli).to receive(:validate).and_return(true)
    allow(Kong::DeckCli).to receive(:diff).and_return({ "changes" => { "creating" => [ { "kind" => "service", "name" => "billing" } ], "updating" => [], "deleting" => [] } })
  end

  def add_create_item(changeset, name)
    create(:change_plan, changeset: changeset, kong_connection: changeset.kong_connection, apply_mode: "pr",
      position: changeset.change_plans.maximum(:position).to_i + 1, operation: "create", entity_type: "service",
      provisional_kong_id: SecureRandom.uuid, target_kong_id: nil, before: {},
      after: { "name" => name, "host" => "#{name}.internal", "tags" => %w[managed-by-kongctl] }, diff: { "operation" => "create" })
  end

  def submitter(**overrides)
    described_class.new(changeset: changeset, client: nil, secret: "pw", actor_username: "a", actor_operator: nil, **overrides)
  end

  def branches
    Open3.capture3("git", "--git-dir=#{repo}", "branch", "--list", "kongctl/*").first
  end

  it "pushes one branch with every item, a Changed-by trailer, and records the result" do
    add_create_item(changeset, "billing")
    add_create_item(changeset, "ledger")

    result = described_class.new(changeset: changeset, client: nil, secret: "pw", actor_username: "kong-admin",
      actor_operator: "somchai@example.com").call

    expect(result).to have_attributes(status: "submitted", branch: "kongctl/changeset-#{changeset.id}", submitted_by: "kong-admin")
    log = Open3.capture3("git", "--git-dir=#{repo}", "log", "-1", "--format=%B", "kongctl/changeset-#{changeset.id}").first
    expect(log).to include("Changed-by: somchai@example.com")
    expect(Open3.capture3("git", "--git-dir=#{repo}", "rev-list", "--count", "main..kongctl/changeset-#{changeset.id}").first.strip).to eq("1")
    yaml = Open3.capture3("git", "--git-dir=#{repo}", "show", "kongctl/changeset-#{changeset.id}:uat/kong.yaml").first
    expect(yaml).to include("name: billing", "name: ledger")
    expect { Kong::DeckDocument.verify_input!(yaml) }.not_to raise_error
    expect(changeset.change_plans.reload.map(&:status)).to all(eq("applied"))
    expect(changeset.change_plans.map(&:pr_state)).to all(eq("branch_pushed"))
    expect(AuditEvent.where(change_plan_id: changeset.change_plans.ids).count).to eq(2)
    expect(result.pr_body).to include("billing", "ledger", "Changed-by: somchai@example.com")
    expect(result.commit_sha).to be_present
  end

  it "blocks before pushing when the diff deletes more than the project's threshold" do
    project.update!(delete_threshold: 1)
    allow(Kong::DeckCli).to receive(:diff).and_return({ "changes" => { "creating" => [], "updating" => [],
      "deleting" => [ { "kind" => "service", "name" => "a" }, { "kind" => "service", "name" => "b" } ] } })
    add_create_item(changeset, "billing")

    expect { submitter.call }.to raise_error(Kong::ChangeGuardrails::Violation, /over the threshold of 1/)
    expect(branches).to be_empty
    expect(changeset.reload).to be_open
  end

  it "blocks an item on the admin path, even one that got in before the planner refused them" do
    admin_id = SecureRandom.uuid
    connection.update!(admin_path_fingerprint: { "service_id" => admin_id, "route_ids" => [], "plugin_ids" => [], "consumer_ids" => [] })
    create(:change_plan, changeset: changeset, kong_connection: connection, apply_mode: "pr", position: 1,
      operation: "update", target_kong_id: admin_id)
    expect { submitter.call }.to raise_error(Kong::ChangeGuardrails::Violation, /admin path/)
    expect(branches).to be_empty
  end

  it "leaves everything as it was when decK rejects the file" do
    allow(Kong::DeckCli).to receive(:validate).and_raise(Kong::DeckCli::Error, "deck file validate failed: bad")
    add_create_item(changeset, "billing")
    expect { submitter.call }.to raise_error(Kong::DeckCli::Error)
    expect(changeset.reload).to have_attributes(status: "open", failure_reason: include("deck file validate failed"))
    expect(changeset.items.map(&:status)).to all(eq("pending"))
    expect(branches).to be_empty
    status, = Open3.capture3("git", "status", "--porcelain", chdir: Kong::GitClient.new(connection: connection).working_dir.to_s)
    expect(status).to be_empty
  end

  it "requires acknowledging drift before submitting over it" do
    changeset.update!(base_git_sha: "0" * 40)
    add_create_item(changeset, "billing")
    expect { submitter.call }.to raise_error(Kong::ChangeGuardrails::Violation, /changed since this changeset began/)
    expect(submitter(acknowledge_drift: true).call.status).to eq("submitted")
  end

  it "refuses an empty changeset, and one already submitted" do
    expect { submitter.call }.to raise_error(Kong::ChangeGuardrails::Violation, /no items/)
    changeset.update!(status: "submitted")
    expect { submitter.call }.to raise_error(Kong::ChangeGuardrails::Violation, /submitted, not open/)
  end

  it "scrubs a token in the repo URL out of the stored failure reason" do
    add_create_item(changeset, "billing")
    allow_any_instance_of(Kong::GitClient).to receive(:push!)
      .and_raise(Kong::GitClient::Error, "git push failed: fatal: https://kongctl:s3cr3t-token@git.example/team/repo.git rejected")
    expect { submitter.call }.to raise_error(Kong::GitClient::Error)
    expect(changeset.reload.failure_reason).not_to include("s3cr3t-token")
    expect(changeset.items.map(&:status)).to all(eq("pending"))
  end

  it "makes no write call to Kong" do
    add_create_item(changeset, "billing")
    submitter.call
    expect(a_request(:any, //).with { |req| %i[post put patch delete].include?(req.method) }).not_to have_been_made
  end
  # R8.7: every example ChangeApplier's single-plan PR path had, now through
  # the one PR path left -- a changeset submit. Same fixtures, same promises;
  # where a failure used to mark the plan failed, the item now stays pending
  # and the reason sits on the changeset.
  describe "carried over from ChangeApplier's PR mode" do
    def pushed_yaml
      Open3.capture3("git", "--git-dir=#{repo}", "show", "kongctl/changeset-#{changeset.id}:uat/kong.yaml").first
    end

    def tool_yaml(text)
      Kong::DeckDocument.serialize(Kong::DeckDocument.parse(text, select_tags: [ "managed-by-kongctl" ]))
    end

    def seed!(text)
      dir = @bare_git_tmp.join("reseed-#{SecureRandom.hex(4)}")
      Open3.capture3("git", "clone", repo.to_s, dir.to_s)
      File.write(dir.join("uat", "kong.yaml"), text)
      Open3.capture3("git", "add", "-A", chdir: dir.to_s)
      Open3.capture3("git", "-c", "user.name=seed", "-c", "user.email=seed@example.com", "commit", "-m", "reseed", chdir: dir.to_s)
      _, err, status = Open3.capture3("git", "push", "origin", "main", chdir: dir.to_s)
      raise err unless status.success?
    end

    def item(entity_type:, operation: "create", after: {}, before: {}, target_kong_id: nil, parent_kong_id: nil)
      create(:change_plan, changeset: changeset, kong_connection: connection, apply_mode: "pr",
        position: changeset.change_plans.maximum(:position).to_i + 1, entity_type: entity_type, operation: operation,
        target_kong_id: target_kong_id, parent_kong_id: parent_kong_id, before: before, after: after, base_updated_at: nil)
    end

    def submit(**extra)
      submitter(**extra).call
    end

    let(:pem) { PemFixtures.self_signed(days: 60)[:cert_pem] }

    it "diffs against Kong with the read-only credential already in hand" do
      add_create_item(changeset, "billing")
      submit
      expect(Kong::DeckCli).to have_received(:diff).with(anything, connection: connection, secret: "pw", extra_paths: [])
      expect(Open3.capture3("git", "--git-dir=#{repo}", "show", "main:uat/kong.yaml").first).not_to include("billing")
    end

    it "refuses the admin path before the repo is even pulled" do
      admin_id = SecureRandom.uuid
      connection.update!(admin_path_fingerprint: { "service_id" => admin_id })
      item(entity_type: "service", operation: "update", target_kong_id: admin_id,
        before: { "id" => admin_id, "name" => "admin-api" }, after: { "id" => admin_id, "name" => "admin-api", "tags" => [ "x" ] })
      expect { submit }.to raise_error(Kong::ChangeGuardrails::Violation, /never rendered/)
      expect(Kong::GitClient).not_to have_received(:new)
    end

    it "renders a route nested under its service, found through the read-model" do
      service_id = "aaaaaaaa-0000-0000-0000-0000000000a1"
      create(:kong_entity, kong_connection: connection, entity_type: "service", kong_id: service_id, name: "orders")
      seed!(tool_yaml("services:\n  - name: orders\n    url: http://orders:80\n"))
      item(entity_type: "route", after: { "name" => "orders-route", "paths" => [ "/o" ], "service" => { "id" => service_id } })

      submit

      expect(YAML.safe_load(pushed_yaml)["services"][0]["routes"]).to eq([ { "name" => "orders-route", "paths" => [ "/o" ] } ])
    end

    it "renders an upstream, and a target nested under it" do
      upstream_id = "aaaaaaaa-0000-0000-0000-0000000000a2"
      create(:kong_entity, kong_connection: connection, entity_type: "upstream", kong_id: upstream_id, name: "orders-up")
      seed!(tool_yaml("upstreams:\n  - name: orders-up\n"))
      item(entity_type: "target", parent_kong_id: upstream_id, after: { "target" => "10.0.0.1:80", "weight" => 100 })

      submit

      expect(YAML.safe_load(pushed_yaml)["upstreams"][0]["targets"]).to eq([ { "target" => "10.0.0.1:80", "weight" => 100 } ])
    end

    it "mints the certificate id, persists it on the item and records it in the audit event; a vault-referenced key needs the acknowledgement" do
      plan = item(entity_type: "certificate", after: { "cert" => pem, "key" => "{vault://env/cert-pay-key}", "snis" => [ "pay.example.internal" ] })

      expect { submit }.to raise_error(Kong::ChangeGuardrails::Violation, /CERT_PAY_KEY/)
      expect(plan.reload.status).to eq("pending")

      submit(env_acknowledged: true)

      minted = plan.reload.target_kong_id
      expect(minted).to match(/\A\h{8}-\h{4}-\h{4}-\h{4}-\h{12}\z/)
      event = AuditEvent.find_by!(change_plan: plan)
      expect(event.target_kong_id).to eq(minted)
      expect(event.context).to include("acknowledged_env_vars" => [ "CERT_PAY_KEY" ], "changeset_id" => changeset.id)
      certificate = YAML.safe_load(pushed_yaml)["certificates"][0]
      expect(certificate).to include("id" => minted, "key" => "{vault://env/cert-pay-key}", "snis" => [ { "name" => "pay.example.internal" } ])
    end

    it "does not persist a freshly minted certificate id when a later step fails: the item stays pending with no target_kong_id" do
      allow(Kong::DeckCli).to receive(:validate).and_raise(Kong::DeckCli::Error, "deck file validate failed: boom")
      plan = item(entity_type: "certificate", after: { "cert" => pem, "key" => %q(${{ env "DECK_CERT_PAY_KEY" }}) })

      expect { submit }.to raise_error(Kong::DeckCli::Error)

      expect(plan.reload).to have_attributes(status: "pending", target_kong_id: nil)
      expect(changeset.reload.failure_reason).to include("deck file validate failed: boom")
    end

    it "does not persist a minted certificate id when a refusal follows the render" do
      plan = item(entity_type: "certificate", after: { "cert" => pem, "key" => %q(${{ env "DECK_CERT_PAY_KEY" }}) })
      allow(Kong::DeckDocument).to receive(:serialize).and_raise(Kong::DeckDocument::Unparseable, "cannot reproduce")

      expect { submit }.to raise_error(Kong::DeckDocument::Unparseable)

      expect(plan.reload).to have_attributes(status: "pending", target_kong_id: nil)
      expect(branches).to be_empty
    end

    it "scrubs a PEM block out of the stored reason -- decK and git stderr can echo the file they choked on" do
      allow(Kong::DeckCli).to receive(:validate).and_raise(
        Kong::DeckCli::Error, "deck file validate failed\n-----BEGIN PRIVATE KEY-----\nAAAA\n-----END PRIVATE KEY-----"
      )
      add_create_item(changeset, "billing")

      expect { submit }.to raise_error(Kong::DeckCli::Error)

      expect(changeset.reload.failure_reason).to include("deck file validate failed")
      expect(changeset.failure_reason).not_to include("AAAA")
    end

    it "caps the stored reason so a verbose git stderr cannot bury the page" do
      allow(Kong::DeckCli).to receive(:validate).and_raise(Kong::GitClient::Error, "boom " * 2000)
      add_create_item(changeset, "billing")

      expect { submit }.to raise_error(Kong::GitClient::Error)

      expect(changeset.reload.failure_reason.length).to be <= Kong::ChangesetRenderer::MESSAGE_LIMIT
    end

    it "renders a decK placeholder double-quoted for decK and asks for no acknowledgement: CI resolves the variable" do
      item(entity_type: "certificate", after: { "cert" => pem, "key" => %q(${{ env "DECK_CERT_PAY_KEY" }}) })

      submit

      expect(pushed_yaml).to include(%q(key: "${{ env "DECK_CERT_PAY_KEY" }}"))
    end

    it "keeps what it does not manage: vaults, consumer_groups and flat routes survive an edit" do
      seed!(tool_yaml("vaults:\n  - name: env\n    prefix: env\nconsumer_groups:\n  - name: gold-tier\nroutes:\n  - name: flat-route\n"))
      item(entity_type: "service", after: { "name" => "orders", "url" => "http://orders:80" })

      submit

      expect(pushed_yaml).to include("vaults:", "gold-tier", "flat-route", "name: orders")
    end

    it "refuses a config file it could not reproduce, before decK runs: nothing pushed, items pending" do
      seed!("_format_version: '3.0'\n_info:\n  select_tags: [managed-by-kongctl]\nservices:\n  - {name: orders, url: 'http://orders:80'}\n")
      plan = item(entity_type: "service", after: { "name" => "billing" })

      expect { submit }.to raise_error(Kong::DeckDocument::Unparseable, /would not survive a re-render/)

      expect(plan.reload.status).to eq("pending")
      expect(branches).to be_empty
      expect(Kong::DeckCli).not_to have_received(:validate)
    end

    it "refuses a change it cannot render faithfully (an unnamed route)" do
      service_id = "aaaaaaaa-0000-0000-0000-0000000000a1"
      create(:kong_entity, kong_connection: connection, entity_type: "service", kong_id: service_id, name: "orders")
      seed!(tool_yaml("services:\n  - name: orders\n"))
      plan = item(entity_type: "route", after: { "paths" => [ "/o" ], "service" => { "id" => service_id } })

      expect { submit }.to raise_error(Kong::DeckRenderer::Unrenderable, /a route needs a name/)

      expect(plan.reload.status).to eq("pending")
      expect(branches).to be_empty
    end

    it "refuses a connection with no select_tags before pulling the repo: decK would treat an empty filter as the whole workspace" do
      add_create_item(changeset, "billing")
      [ [], [ "" ], [ " ", "" ], nil ].each do |tags|
        connection.update_columns(select_tags: tags)

        expect { submit }.to raise_error(Kong::ChangeGuardrails::Violation, /no select_tags.*whole workspace/)

        expect(Kong::GitClient).not_to have_received(:new)
        expect(branches).to be_empty
      end
    end

    it "says where a serializer bug bites: the round-trip refusal carries the first-difference line" do
      calls = 0
      allow(Kong::DeckDocument).to receive(:verify_input!).and_wrap_original do |original, text|
        calls += 1
        calls == 1 ? original.call(text) : raise(Kong::DeckDocument::Unparseable, "the config YAML would not survive a re-render unchanged (first difference at line 7) -- rewrite it")
      end
      plan = item(entity_type: "service", after: { "name" => "billing" })

      expect { submit }.to raise_error(Kong::ChangeGuardrails::Violation, /did not round-trip byte-for-byte.*first difference at line 7/)

      expect(plan.reload.status).to eq("pending")
      expect(branches).to be_empty
    end

    it "raises the deliberate NotImplementedError for a credential before it even pulls the repo" do
      plan = item(entity_type: "keyauth_credential", parent_kong_id: "aaaaaaaa-0000-0000-0000-0000000000a3", after: { "key" => "x" })

      expect { submit }.to raise_error(NotImplementedError, /keyauth_credential is deliberately never rendered/)

      expect(plan.reload.status).to eq("pending")
      expect(Kong::GitClient).not_to have_received(:new)
    end
  end
  # Final review #1: a real commit to the same entity after the item was
  # proposed survives the push; one to the same field is refused by name.
  describe "an update proposed before git moved" do
    def seed_service!(fields)
      dir = @bare_git_tmp.join("reseed-#{SecureRandom.hex(4)}")
      Open3.capture3("git", "clone", repo.to_s, dir.to_s)
      text = Kong::DeckDocument.serialize(Kong::DeckDocument.parse({ "services" => [ { "name" => "orders" }.merge(fields) ] }.to_yaml.sub(/\A---\n/, ""), select_tags: %w[managed-by-kongctl]))
      File.write(dir.join("uat", "kong.yaml"), text)
      Open3.capture3("git", "add", "-A", chdir: dir.to_s)
      Open3.capture3("git", "-c", "user.name=bob", "-c", "user.email=bob@example.com", "commit", "-m", "bob", chdir: dir.to_s)
      Open3.capture3("git", "push", "origin", "main", chdir: dir.to_s)
    end

    def update_item(from:, to:)
      create(:change_plan, changeset: changeset, kong_connection: connection, apply_mode: "pr", position: 1, operation: "update",
        entity_type: "service", target_kong_id: SecureRandom.uuid, base_updated_at: nil,
        before: { "name" => "orders", "retries" => 5, "read_timeout" => from },
        after: { "name" => "orders", "retries" => 5, "read_timeout" => to },
        diff: { "read_timeout" => { "from" => from, "to" => to } })
    end

    it "keeps another field someone changed in git in the meantime" do
      seed_service!("url" => "http://orders:80", "retries" => 5, "read_timeout" => 60000)
      update_item(from: 60000, to: 30000)
      seed_service!("url" => "http://orders:80", "retries" => 10, "read_timeout" => 60000)

      submitter.call

      yaml = Open3.capture3("git", "--git-dir=#{repo}", "show", "kongctl/changeset-#{changeset.id}:uat/kong.yaml").first
      expect(YAML.safe_load(yaml)["services"]).to eq([ { "name" => "orders", "read_timeout" => 30000, "retries" => 10, "url" => "http://orders:80" } ])
    end

    it "refuses when git changed the same field in the meantime" do
      seed_service!("url" => "http://orders:80", "read_timeout" => 60000)
      update_item(from: 60000, to: 30000)
      seed_service!("url" => "http://orders:80", "read_timeout" => 45000)

      expect { submitter.call }.to raise_error(Kong::DeckRenderer::Unrenderable, /read_timeout of service orders changed in git/)
      expect(branches).to be_empty
    end
  end
  # Final review #2: what a submit renders is what the PR says, and a submit
  # that lost the race to another never writes onto the winner.
  describe "while other work touches the changeset" do
    it "describes, in the commit and the PR body, exactly the items it rendered" do
      add_create_item(changeset, "billing")
      allow(Kong::DeckCli).to receive(:validate) do
        add_create_item(changeset, "late-arrival") # proposed while decK was running
        true
      end

      result = submitter.call

      log = Open3.capture3("git", "--git-dir=#{repo}", "log", "-1", "--format=%B", "kongctl/changeset-#{changeset.id}").first
      expect(log).to include("billing")
      expect(log).not_to include("late-arrival")
      expect(result.pr_body).not_to include("late-arrival")
    end

    it "refuses, and records nothing, when another submit got there first" do
      add_create_item(changeset, "billing")
      stale = submitter
      Changeset.where(id: changeset.id).update_all(status: "submitted", branch: "kongctl/changeset-#{changeset.id}")

      expect { stale.call }.to raise_error(Kong::ChangeGuardrails::Violation, /submitted, not open/)
      expect(changeset.reload.failure_reason).to be_nil
    end
  end

  # Final review #3: one working copy per connection -- a preview and a submit
  # (or two of either) never run git in it at the same time.
  it "waits for another git operation on the same connection before touching the working copy" do
    add_create_item(changeset, "billing")
    events = Queue.new
    # Another Postgres session -- another request or process -- holding the
    # lock. (The test's own connection is shared across threads, and advisory
    # locks nest within a session, so it cannot stand in for a second one.)
    config = ActiveRecord::Base.connection_db_config.configuration_hash
    holder = Thread.new do
      other = PG.connect(host: config[:host], port: config[:port], user: config[:username], password: config[:password], dbname: config[:database])
      other.exec("SELECT pg_advisory_lock(#{Kong::GitClient::LOCK_NAMESPACE}, #{connection.id})")
      events << :held
      sleep 0.6
      events << :released
      other.exec("SELECT pg_advisory_unlock(#{Kong::GitClient::LOCK_NAMESPACE}, #{connection.id})")
    ensure
      other&.close
    end
    sleep 0.2
    allow_any_instance_of(Kong::GitClient).to receive(:pull!).and_wrap_original { |m, *a| events << :pull; m.call(*a) }

    submitter.call
    holder.join

    expect(Array.new(events.size) { events.pop }.first(3)).to eq(%i[held released pull])
  end

  # Final review #4: at uat/prod a delete still asks for the entity's own name,
  # item by item, as the single-plan apply did.
  describe "a delete at rank >= 2" do
    before { seed_orders }

    def seed_orders
      dir = @bare_git_tmp.join("seed-orders-#{SecureRandom.hex(4)}")
      Open3.capture3("git", "clone", repo.to_s, dir.to_s)
      File.write(dir.join("uat", "kong.yaml"), Kong::DeckDocument.serialize(Kong::DeckDocument.parse("services:\n  - name: orders\n", select_tags: %w[managed-by-kongctl])))
      Open3.capture3("git", "add", "-A", chdir: dir.to_s)
      Open3.capture3("git", "-c", "user.name=s", "-c", "user.email=s@example.com", "commit", "-m", "s", chdir: dir.to_s)
      Open3.capture3("git", "push", "origin", "main", chdir: dir.to_s)
    end

    let!(:delete_item) do
      create(:change_plan, :delete, changeset: changeset, kong_connection: connection, apply_mode: "pr", position: 1,
        entity_type: "service", before: { "id" => SecureRandom.uuid, "name" => "orders", "tags" => [] })
    end

    it "refuses without the typed name, and with a wrong one" do
      expect { submitter.call }.to raise_error(Kong::ChangeGuardrails::Violation, /deleting orders requires typing its name/)
      expect { submitter(delete_confirmations: { delete_item.id.to_s => "order" }).call }
        .to raise_error(Kong::ChangeGuardrails::Violation, /does not match/)
      expect(branches).to be_empty
    end

    it "submits once the name is typed" do
      expect(submitter(delete_confirmations: { delete_item.id.to_s => "orders" }).call.status).to eq("submitted")
    end
  end
end
