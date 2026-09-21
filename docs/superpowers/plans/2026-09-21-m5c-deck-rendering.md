# M5c — decK rendering for every managed type: Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** A PR-mode apply renders any of the 9 managed entity types into the connection's decK YAML, preserves everything it does not manage, refuses to write anything it cannot render faithfully, and every one of those claims is checked against a real decK binary.

**Architecture:** `Kong::EntityTypes::Definition` gains the decK facts (collection, identity key, parent-reference fields). A new `Kong::DeckDocument` owns the file format (parse, deterministic serialize, the fail-closed input guard). `Kong::DeckRenderer` is narrowed to `apply_change`, which locates the entity through the registry and mutates the document, resolving parents through the read-model. `Kong::DeckCli` is fixed to run the commands decK actually has, and `Kong::CiGate` is fixed to read decK's real diff shape. The applier's `execute_pr!` loses its service-only guard.

**Tech Stack:** Rails 8.1, RSpec, decK 1.51.1 / 1.66.1 (both verified identical), Kong 3.7.1 CE.

**Spec:** `docs/superpowers/specs/2026-09-21-m5c-deck-rendering-design.md` (binding; read §1 for every measured decK fact and the correction note at the top of §6). This plan was written against **prototype code that already passed against real decK** (serializer 30/30, renderer 16/16, legacy skeleton 5/5): the code in Tasks 4-5 is that code, not a fresh guess.

## Global Constraints

Every task's requirements include this section.

- **decK commands (measured, both versions):** the file is a **positional** argument — there is **no `-s` flag**. Offline check is `deck file validate <file>`. `deck gateway validate` is *online* and is not used. The diff is `deck gateway diff <file> --kong-addr <url> --headers <k:v> --json-output`; its stdout is JSON, exit code 0 even when changes exist.
- **decK diff shape:** `{"changes": {"creating": [..], "updating": [..], "deleting": [..]}, "summary": {..}, "warnings": [], "errors": []}`; each entry `{"name", "kind", "body": {"new", "old"}}`.
- **decK's schema is closed:** an unknown top-level key or unknown field on an entity is rejected. Valid keys this tool does not manage (`vaults`, `consumer_groups`, `routes`, …) must be preserved untouched.
- **What a rendered entity may contain:** no `null` values (decK rejects `custom_id: null`), no `created_at`/`updated_at`, no `id` (**except `certificate`, where decK requires it**; `ca_certificate` does not need one), and no reference to the parent it is nested inside (`service`, `upstream`, `certificate`, and a plugin's `service`/`route`/`consumer`). A `route` **must** have a `name`.
- **Nesting is mandatory for children:** `target` only under `upstreams[].targets[]`; `route` under `services[].routes[]`; `sni` under `certificates[].snis[]`; a `plugin` under its scope's `plugins[]`, or top-level `plugins[]` when global.
- **The decK env placeholder is emitted single-quoted:** `key: '${{ env "DECK_X" }}'`. It is a textual substitution done *before* YAML parsing, so this is the only form both decK and Ruby's YAML parser accept.
- **The tool never sees a real private key.** `deck file validate` and `deck gateway diff` run on Kongsole's host and both need every referenced `DECK_*` variable to exist, so `DeckCli` sets the fixed dummy `kongsole-validation-placeholder` for each one. CI resolves the real value.
- **Credentials are never rendered.** `keyauth_credential` / `basicauth_credential` in PR mode raise `NotImplementedError` saying the exclusion is deliberate (docs/DESIGN.md §1.7).
- **Fail closed, before anything is written:** input that does not round-trip; a route with no name; a child whose parent is not in the file; a certificate update whose YAML entry has no matching `id`. A failure to render is always an error, never a silent omission.
- **M5b invariants still hold:** a private key (PEM) is never accepted, stored, logged, echoed back or returned by any surface; every echoed error string goes through `Kong::CertificateKeyPolicy.scrub`.
- **Repo hygiene:** never touch `mcp/src/config.ts` (hardcoded token, out of scope) or the user's modified `.gitattributes`, `Gemfile.lock`, `config/database.yml`; never `git add -A` / `git add .`; keep touched files CRLF; nothing is pushed.

## Running things on this machine

Same environment gaps as M5b (do not "fix" the repo for them):

```bash
cd /d/kongsole
export DATABASE_URL="postgres://kongsole:kongsole@localhost:5433/kong_integration_test"
K="C:/Users/66880/AppData/Local/Temp/claude/d--kongsole/06b4608a-a6d3-494b-8684-2c796edce238/scratchpad/test_encryption_keys.rb"
bundle exec rspec -r "$K" <paths>      # whole suite: bundle exec rspec -r "$K"   (baseline 545 examples, 0 failures)
bundle exec rubocop <files>
```

**A real decK binary** (needed by the opt-in tests and the live check). Already extracted this session; if the directory is gone, download it:

```bash
SP="C:/Users/66880/AppData/Local/Temp/claude/d--kongsole/06b4608a-a6d3-494b-8684-2c796edce238/scratchpad"
ls "$SP/deck1661/deck.exe" "$SP/deck1511/deck.exe"    # both should exist
# if missing:
#   mkdir -p "$SP/deck1661" && curl -sL -o "$SP/deck1661/deck.tar.gz" https://github.com/Kong/deck/releases/download/v1.66.1/deck_1.66.1_windows_amd64.tar.gz && tar -xzf "$SP/deck1661/deck.tar.gz" -C "$SP/deck1661"
#   (same with v1.51.1 into deck1511)
export DECK_BIN="$SP/deck1661/deck.exe"
```

The Bash tool rejects long heredocs: create files with Write/Edit. New files must be normalised with `sed -i 's/\r$//; s/$/\r/' <file>`. Line endings are checked with a Ruby count (`File.binread(f).scan("\r\n").size` equals `count("\n")`).

## File Structure

**Create**
- `app/services/kong/deck_document.rb` — the decK file format: `parse`, `serialize`, `verify_input!`.
- `app/services/kong/deck_read_model_resolver.rb` — answers "what is this kong_id called in YAML" from the read-model.
- `spec/services/kong/deck_cli_spec.rb`, `spec/services/kong/deck_document_spec.rb`, `spec/services/kong/deck_read_model_resolver_spec.rb`
- `spec/fixtures/deck/gateway_diff_creating.json`, `spec/fixtures/deck/gateway_diff_deleting.json` — real decK output.

**Modify**
- `app/services/kong/deck_cli.rb`, `app/services/kong/ci_gate.rb`, `app/services/kong/entity_types.rb`, `app/services/kong/deck_renderer.rb`, `app/services/kong/change_applier.rb`
- `app/controllers/change_plans_controller.rb`, `app/controllers/api/v1/change_plans_controller.rb`, `app/views/change_plans/show.html.erb`
- `lib/tasks/kong.rake`, `spec/requests/change_plans_spec.rb`, `spec/services/kong/change_applier_spec.rb`, `spec/services/kong/deck_renderer_spec.rb`, `spec/services/kong/ci_gate_spec.rb`, `spec/services/kong/entity_types_spec.rb`
- `README.md`, `docs/DESIGN.md`, `docs/DESIGN.html`

## Noticed, deliberately not taken by this plan

- `DeckCli#diff` passes the read-only Basic credential in argv, visible to `ps`. decK reads `DECK_KONG_ADDR` from the environment (measured), so `DECK_HEADERS` is the likely fix; that needs its own verification. Pre-existing, unchanged here.
- Carried from M5b's final review (spec §10): `expiring_within` does not exclude soft-deleted rows; a non-Hash `attributes` 500s on `POST /api/v1/change_plans`; `fields[]=x` 500s on the entities API; `audit_events.context` is not surfaced in the UI.
- Opening the PR itself (host API tokens, webhooks, CI wiring) — its own milestone.

---

### Task 1: `Kong::DeckCli` runs the commands decK actually has

**Files:**
- Modify: `app/services/kong/deck_cli.rb`
- Create: `spec/services/kong/deck_cli_spec.rb`

**Interfaces:**
- Consumes: `Kong::CertificateKeyPolicy.scrub(text)` (M5b).
- Produces:
  - `Kong::DeckCli.validate(file_path)` → `true`, or raises `Kong::DeckCli::Error`. Runs `deck file validate <file>` (offline).
  - `Kong::DeckCli.diff(file_path, connection:, secret:)` → the parsed `--json-output` Hash (`{}` when stdout is blank). Runs `deck gateway diff <file> --kong-addr … --headers … --json-output`.
  - `Kong::DeckCli::PLACEHOLDER_VALUE` (`"kongsole-validation-placeholder"`).
  - The binary is `ENV["DECK_BIN"]` when set, else `"deck"`.
  - Every `DECK_*` variable the file references (`${{ env "DECK_X" }}`) is passed to the process with `PLACEHOLDER_VALUE`, overriding whatever the real environment holds.

Why: measured against real decK 1.51.1 and 1.66.1 — `-s` exists on neither (`unknown shorthand flag: 's' in -s`), and `deck gateway validate` is an *online* command. `Kong::DeckCli` had no spec and the applier spec stubs it, so neither defect was ever visible.

- [ ] **Step 1: Write the failing spec**

Create `spec/services/kong/deck_cli_spec.rb`:

```ruby
require "rails_helper"
require Rails.root.join("spec/support/pem_fixtures")

RSpec.describe Kong::DeckCli do
  let(:success) { instance_double(Process::Status, success?: true) }
  let(:failure) { instance_double(Process::Status, success?: false) }
  let(:file) { Rails.root.join("tmp", "deck_cli_spec.yaml") }

  describe "with the process boundary stubbed" do
    around do |example|
      saved = ENV["DECK_BIN"]
      ENV.delete("DECK_BIN")
      example.run
    ensure
      ENV["DECK_BIN"] = saved
    end

    before do
      FileUtils.mkdir_p(file.dirname)
      File.write(file, "_format_version: '3.0'\n")
      allow(Open3).to receive(:capture3).and_return([ "", "", success ])
    end

    after { FileUtils.rm_f(file) }

    describe ".validate" do
      it "runs the OFFLINE `deck file validate` with the file as a positional argument (no -s, not `gateway`)" do
        expect(described_class.validate(file)).to be(true)

        expect(Open3).to have_received(:capture3).with({}, "deck", "file", "validate", file.to_s)
      end

      it "uses the binary named by DECK_BIN" do
        ENV["DECK_BIN"] = "/opt/deck/deck"

        described_class.validate(file)

        expect(Open3).to have_received(:capture3).with({}, "/opt/deck/deck", "file", "validate", file.to_s)
      end

      it "gives every DECK_ variable the file references a harmless dummy, whatever the real environment holds" do
        File.write(file, <<~YAML)
          key: '${{ env "DECK_SPEC_ONE_KEY" }}'
          other: '${{ env "DECK_SPEC_TWO_KEY" }}'
          again: '${{ env "DECK_SPEC_ONE_KEY" }}'
        YAML
        ENV["DECK_SPEC_ONE_KEY"] = "the-real-secret"

        begin
          described_class.validate(file)
        ensure
          ENV.delete("DECK_SPEC_ONE_KEY")
        end

        expect(Open3).to have_received(:capture3).with(
          { "DECK_SPEC_ONE_KEY" => described_class::PLACEHOLDER_VALUE, "DECK_SPEC_TWO_KEY" => described_class::PLACEHOLDER_VALUE },
          "deck", "file", "validate", file.to_s
        )
      end

      it "raises decK's own message, scrubbed of any private key and bounded in length" do
        stderr = "Error: routes.0: name is required\n-----BEGIN PRIVATE KEY-----\nAAAA\n-----END PRIVATE KEY-----\n#{'x' * 5000}"
        allow(Open3).to receive(:capture3).and_return([ "", stderr, failure ])

        expect { described_class.validate(file) }.to raise_error(described_class::Error) { |error|
          expect(error.message).to include("deck file validate failed", "name is required")
          expect(error.message).not_to include("AAAA")
          expect(error.message.length).to be < 2200
        }
      end

      it "explains a missing binary instead of leaking Errno::ENOENT" do
        allow(Open3).to receive(:capture3).and_raise(Errno::ENOENT)

        expect { described_class.validate(file) }.to raise_error(described_class::Error, /wasn't found.*DECK_BIN/m)
      end
    end

    describe ".diff" do
      let(:connection) { build(:kong_connection, admin_url: "https://kong-uat-admin-ro.internal", auth_username: "reader") }
      let(:header) { "Authorization:Basic #{Base64.strict_encode64('reader:pw')}" }

      it "runs `deck gateway diff` with the file positional, against the connection, asking for JSON" do
        allow(Open3).to receive(:capture3).and_return([ { "changes" => { "creating" => [] } }.to_json, "", success ])

        result = described_class.diff(file, connection: connection, secret: "pw")

        expect(result).to eq({ "changes" => { "creating" => [] } })
        expect(Open3).to have_received(:capture3).with(
          {}, "deck", "gateway", "diff", file.to_s,
          "--kong-addr", "https://kong-uat-admin-ro.internal", "--headers", header, "--json-output"
        )
      end

      it "treats blank output as no changes" do
        expect(described_class.diff(file, connection: connection, secret: "pw")).to eq({})
      end

      it "raises decK's message when the diff fails" do
        allow(Open3).to receive(:capture3).and_return([ "", "Error: cannot reach Kong", failure ])

        expect { described_class.diff(file, connection: connection, secret: "pw") }
          .to raise_error(described_class::Error, /deck gateway diff failed: Error: cannot reach Kong/)
      end

      it "sets the same dummy variables for the diff, which substitutes the placeholder too" do
        File.write(file, %(key: '${{ env "DECK_SPEC_DIFF_KEY" }}'\n))

        described_class.diff(file, connection: connection, secret: "pw")

        expect(Open3).to have_received(:capture3).with(
          { "DECK_SPEC_DIFF_KEY" => described_class::PLACEHOLDER_VALUE }, "deck", "gateway", "diff", file.to_s,
          "--kong-addr", anything, "--headers", anything, "--json-output"
        )
      end
    end
  end

  # Opt-in: the calls above are only as right as decK says they are. Set DECK_BIN
  # to a real binary (1.51.1 or 1.66.1) to check them for real.
  describe "against a real decK binary", if: ENV["DECK_BIN"].present? do
    let(:dir) { Dir.mktmpdir }
    let(:pem) { PemFixtures.self_signed(cn: "deckcli.example.internal", days: 30)[:cert_pem] }

    after { FileUtils.remove_entry(dir) }

    def write_yaml(text)
      Pathname(dir).join("kong.yaml").tap { |path| File.write(path, text) }
    end

    it "accepts a valid nested document" do
      path = write_yaml(<<~YAML)
        _format_version: '3.0'
        _info:
          select_tags:
            - team-a
        services:
          - name: orders
            url: http://orders:80
            routes:
              - name: orders-route
                paths:
                  - "/orders"
      YAML

      expect(described_class.validate(path)).to be(true)
    end

    it "rejects an unnamed route with decK's own message" do
      path = write_yaml(<<~YAML)
        _format_version: '3.0'
        _info:
          select_tags:
            - team-a
        services:
          - name: orders
            url: http://orders:80
            routes:
              - paths:
                  - "/orders"
      YAML

      expect { described_class.validate(path) }.to raise_error(described_class::Error, /name is required/)
    end

    it "validates a decK placeholder without the real variable ever being set" do
      ENV.delete("DECK_REAL_SPEC_KEY")
      body = pem.lines.map { |line| "      #{line}" }.join
      path = write_yaml(<<~YAML)
        _format_version: '3.0'
        _info:
          select_tags:
            - team-a
        certificates:
          - id: 11111111-2222-3333-4444-555555555555
            cert: |
        #{body}
            key: '${{ env "DECK_REAL_SPEC_KEY" }}'
      YAML

      expect(described_class.validate(path)).to be(true)
    end
  end
end
```

- [ ] **Step 2: Run it and confirm it fails for the right reason**

Run: `bundle exec rspec -r "$K" spec/services/kong/deck_cli_spec.rb`

Expected: the stubbed examples FAIL — `expected: ({}, "deck", "file", "validate", …) got: ("deck", "gateway", "validate", "-s", …)` and `PLACEHOLDER_VALUE` is an uninitialized constant. (The real-binary group is skipped unless `DECK_BIN` is set.)

- [ ] **Step 3: Implement**

Replace the whole of `app/services/kong/deck_cli.rb`:

```ruby
require "open3"
require "base64"

module Kong
  # Shells out to the `deck` CLI to check a rendered YAML file and diff it
  # against a connection's live Kong, using the *read-only* credential already
  # held for the session -- deck never gets a write credential, since PR mode's
  # whole point is that the tool itself cannot write to uat/prod Kong
  # (docs/DESIGN.md section 6 step 4 note).
  #
  # Every invocation below was measured against decK 1.51.1 and 1.66.1 (the two
  # behave identically -- docs/superpowers/specs/2026-09-21-m5c-deck-rendering-
  # design.md section 1): the state file is a POSITIONAL argument (there is no
  # `-s`), and the offline check is `deck file validate` -- `deck gateway
  # validate` is an online command that needs a live Kong.
  class DeckCli
    class Error < StandardError; end

    # decK substitutes `${{ env "DECK_X" }}` as TEXT before it parses the file,
    # and both commands below run on this host, so each referenced variable must
    # exist. The real private key must never be here (M5b), so each one gets
    # this dummy; CI resolves the real value. Any single-line value validates.
    PLACEHOLDER_VALUE = "kongsole-validation-placeholder".freeze
    ENV_REFERENCE = /\$\{\{ env "(DECK_[A-Z0-9_]+)" \}\}/
    MAX_MESSAGE = 2000

    def self.validate(file_path)
      new.validate(file_path)
    end

    def self.diff(file_path, connection:, secret:)
      new.diff(file_path, connection: connection, secret: secret)
    end

    def validate(file_path)
      _stdout, stderr, status = run([ "file", "validate", file_path.to_s ], file_path)
      raise Error, "deck file validate failed: #{clean(stderr)}" unless status.success?

      true
    end

    def diff(file_path, connection:, secret:)
      args = [
        "gateway", "diff", file_path.to_s,
        "--kong-addr", connection.admin_url,
        "--headers", "Authorization:#{basic_auth(connection.auth_username, secret)}",
        "--json-output"
      ]
      stdout, stderr, status = run(args, file_path)
      raise Error, "deck gateway diff failed: #{clean(stderr)}" unless status.success?

      stdout.blank? ? {} : JSON.parse(stdout)
    end

    private

    def bin
      ENV["DECK_BIN"].presence || "deck"
    end

    def run(args, file_path)
      Open3.capture3(placeholder_env(file_path), bin, *args)
    rescue Errno::ENOENT
      raise Error, "the deck binary (#{bin}) wasn't found -- install decK or point DECK_BIN at it"
    end

    def placeholder_env(file_path)
      text = File.exist?(file_path) ? File.read(file_path) : ""
      text.scan(ENV_REFERENCE).flatten.uniq.to_h { |name| [ name, PLACEHOLDER_VALUE ] }
    end

    # decK's own message is what an operator needs; a pasted private key is
    # never allowed through (M5b), and a runaway message is cut.
    def clean(stderr)
      Kong::CertificateKeyPolicy.scrub(stderr).strip.truncate(MAX_MESSAGE)
    end

    def basic_auth(username, secret)
      "Basic #{Base64.strict_encode64("#{username}:#{secret}")}"
    end
  end
end
```

- [ ] **Step 4: Run to green, then RuboCop**

Run: `bundle exec rspec -r "$K" spec/services/kong/deck_cli_spec.rb` — all stubbed examples PASS.

Then with a real binary: `DECK_BIN="$SP/deck1661/deck.exe" bundle exec rspec -r "$K" spec/services/kong/deck_cli_spec.rb` — the three real-binary examples also PASS. Repeat with `deck1511`. If a real-binary example fails, that is a real finding: stop and report it, do not weaken the test.

Run: `bundle exec rubocop app/services/kong/deck_cli.rb spec/services/kong/deck_cli_spec.rb` — no offenses.

- [ ] **Step 5: Run the whole suite**

Run: `bundle exec rspec -r "$K"` — expect 0 failures (the applier spec stubs `DeckCli`, so nothing else is affected).

- [ ] **Step 6: Commit**

Normalise the new spec (`sed -i 's/\r$//; s/$/\r/'`), then:

```bash
git add app/services/kong/deck_cli.rb spec/services/kong/deck_cli_spec.rb
git commit -m "feat(m5c): DeckCli runs the commands decK actually has" -m "Both invocations were wrong on decK 1.51.1 and 1.66.1: -s does not exist (the file is positional) and 'deck gateway validate' is the online command. Adds DECK_BIN, dummy values for referenced DECK_ variables so the real key is never needed here, scrubbed bounded errors, and the class's first spec, including opt-in tests against a real binary." -m "Co-Authored-By: Claude Sonnet 5 <noreply@anthropic.com>"
```

---

### Task 2: `Kong::CiGate` reads decK's real diff shape

**Files:**
- Modify: `app/services/kong/ci_gate.rb`
- Modify: `spec/services/kong/ci_gate_spec.rb`
- Create: `spec/fixtures/deck/gateway_diff_creating.json`, `spec/fixtures/deck/gateway_diff_deleting.json`

**Interfaces:**
- Consumes: nothing new.
- Produces: `Kong::CiGate.check(deck_diff:, admin_path_names:, delete_threshold: nil)` now understands decK's real `--json-output` (a `changes` **Hash** grouped `creating`/`updating`/`deleting`). The pre-M5c flat-array shape (`[{"name", "change"}]`) is still accepted, because plans already stored that shape in `change_plans.deck_diff`.

Why: real output was observed on 2026-09-21. `changes` is a Hash, so `Array(@deck_diff["changes"])` yields `[["creating", [...]], …]` and `change["name"]` raises `TypeError`. **The gate that guards against `deck gateway sync` deleting the admin path (docs/DESIGN.md §1.2, the highest-severity risk) has never worked on real output.** It fails closed only by crashing. A state file with no entities selecting an existing tag reports 94 deletions on the local Kong, so the delete threshold matters.

- [ ] **Step 1: Add the real fixtures**

Create `spec/fixtures/deck/gateway_diff_creating.json` (verbatim real output of `deck gateway diff --json-output`, 1.66.1 and 1.51.1 identical, tab-indented as decK writes it):

```json
{
	"changes": {
		"creating": [
			{
				"name": "m5c-probe-service",
				"kind": "service",
				"body": {
					"new": {
						"connect_timeout": 60000,
						"enabled": true,
						"host": "probe.internal",
						"id": "0ec40c2d-922b-4d37-828c-e0e538b020a5",
						"name": "m5c-probe-service",
						"port": 80,
						"protocol": "http",
						"read_timeout": 60000,
						"retries": 5,
						"write_timeout": 60000,
						"tags": [
							"m5c-diff-probe"
						]
					},
					"old": null
				}
			}
		],
		"updating": [],
		"deleting": []
	},
	"summary": {
		"creating": 1,
		"updating": 0,
		"deleting": 0,
		"total": 1
	},
	"warnings": [],
	"errors": []
}
```

Create `spec/fixtures/deck/gateway_diff_deleting.json` (the same envelope; entries trimmed to the fields the gate reads, which is what a real deleting entry carries plus its `old` body):

```json
{
	"changes": {
		"creating": [],
		"updating": [
			{ "name": "orders", "kind": "service", "body": { "new": { "name": "orders" }, "old": { "name": "orders" } } }
		],
		"deleting": [
			{ "name": "svc-a", "kind": "service", "body": { "new": null, "old": { "name": "svc-a" } } },
			{ "name": "svc-b", "kind": "service", "body": { "new": null, "old": { "name": "svc-b" } } },
			{ "name": "svc-c", "kind": "service", "body": { "new": null, "old": { "name": "svc-c" } } },
			{ "name": "admin-api", "kind": "service", "body": { "new": null, "old": { "name": "admin-api" } } }
		]
	},
	"summary": { "creating": 0, "updating": 1, "deleting": 4, "total": 5 },
	"warnings": [],
	"errors": []
}
```

- [ ] **Step 2: Write the failing specs**

Append inside `RSpec.describe Kong::CiGate` in `spec/services/kong/ci_gate_spec.rb`, before its final `end`:

```ruby
  describe "against real decK --json-output (M5c)" do
    def fixture(name)
      JSON.parse(File.read(Rails.root.join("spec/fixtures/deck", name)))
    end

    it "passes a real diff that only creates something" do
      result = described_class.check(deck_diff: fixture("gateway_diff_creating.json"), admin_path_names: [ "admin-api" ])

      expect(result).to be_passed
      expect(result.reasons).to eq([])
    end

    it "does not count creations or updates as deletions" do
      diff = fixture("gateway_diff_deleting.json")

      result = described_class.check(deck_diff: diff, admin_path_names: [], delete_threshold: 4)

      expect(result).to be_passed
    end

    it "counts the deleting bucket against the threshold" do
      result = described_class.check(deck_diff: fixture("gateway_diff_deleting.json"), admin_path_names: [], delete_threshold: 3)

      expect(result).not_to be_passed
      expect(result.reasons.join).to match(/deletes 4 entities, over the threshold of 3/)
    end

    it "blocks a real diff that touches an admin-path entity, whichever bucket it is in" do
      result = described_class.check(deck_diff: fixture("gateway_diff_deleting.json"), admin_path_names: [ "admin-api" ], delete_threshold: 99)

      expect(result).not_to be_passed
      expect(result.reasons.join).to match(/admin path/)
    end

    it "still accepts the flat shape earlier plans stored" do
      legacy = { "changes" => [ { "name" => "a", "change" => "delete" }, { "name" => "b", "change" => "update" } ] }

      result = described_class.check(deck_diff: legacy, admin_path_names: [], delete_threshold: 0)

      expect(result.reasons.join).to match(/deletes 1 entities/)
    end
  end
```

- [ ] **Step 3: Run and confirm the right failure**

Run: `bundle exec rspec -r "$K" spec/services/kong/ci_gate_spec.rb`

Expected: the five new examples FAIL with `TypeError: no implicit conversion of String into Integer` (from `change["name"]` on an Array) — the crash on real output. The existing examples still PASS.

- [ ] **Step 4: Implement**

In `app/services/kong/ci_gate.rb`, add a constant under `DEFAULT_DELETE_THRESHOLD`:

```ruby
    # decK's `--json-output` groups what will happen to each entity:
    #   {"changes": {"creating": [..], "updating": [..], "deleting": [..]}}
    # every entry {"name", "kind", "body": {"new", "old"}}. The gate reads them
    # as one flat list tagged with the action.
    BUCKETS = { "creating" => "create", "updating" => "update", "deleting" => "delete" }.freeze
```

Replace `entity_changes` and `delete_count`:

```ruby
    def entity_changes
      changes = @deck_diff["changes"] || @deck_diff["entity_changes"]
      return Array(changes) unless changes.is_a?(Hash)

      BUCKETS.flat_map { |bucket, action| Array(changes[bucket]).map { |entry| entry.merge("change" => action) } }
    end

    def touches_admin_path?
      entity_changes.any? { |change| @admin_path_names.include?(change["name"]) }
    end

    # An entry that names its action says so; only the pre-M5c flat shape,
    # which carried just {old, new}, is read by its missing `new`.
    def delete_count
      entity_changes.count { |change| change["change"] ? change["change"] == "delete" : change["new"].nil? }
    end
```

(Delete the old `entity_changes`, `touches_admin_path?` and `delete_count` definitions that these replace; keep `admin_path_reason` and `delete_threshold_reason` as they are.)

- [ ] **Step 5: Run to green, RuboCop, whole suite**

Run: `bundle exec rspec -r "$K" spec/services/kong/ci_gate_spec.rb` — all PASS (the original five examples included).
Run: `bundle exec rubocop app/services/kong/ci_gate.rb spec/services/kong/ci_gate_spec.rb` — no offenses.
Run: `bundle exec rspec -r "$K"` — 0 failures.

- [ ] **Step 6: Commit**

Normalise the two new fixtures and the edited files to CRLF, then:

```bash
git add app/services/kong/ci_gate.rb spec/services/kong/ci_gate_spec.rb spec/fixtures/deck/gateway_diff_creating.json spec/fixtures/deck/gateway_diff_deleting.json
git commit -m "fix(m5c): CiGate reads decK's real --json-output shape" -m "changes is a hash grouped creating/updating/deleting, not an array; the old parsing raised TypeError on real output, so the admin-path and delete-threshold gate never worked. The flat shape earlier plans stored is still accepted." -m "Co-Authored-By: Claude Sonnet 5 <noreply@anthropic.com>"
```

---

### Task 3: The registry knows each type's decK facts

**Files:**
- Modify: `app/services/kong/entity_types.rb`
- Modify: `spec/services/kong/entity_types_spec.rb`

**Interfaces:**
- Consumes: the existing `Kong::EntityTypes::Definition` and `DEFINITIONS`.
- Produces: three new `Definition` members and one predicate, used by Tasks 5-6:
  - `deck_collection` — the YAML list name (`"services"`, `"routes"`, `"targets"`, …), `nil` for a type decK must never receive.
  - `deck_key` — the field identifying an entity inside its YAML list (`"name"`, `"target"`, `"id"`, `"username"`).
  - `deck_refs` — Kong-JSON fields that name the parent an entity is nested inside; stripped when rendering (default `[]`).
  - `deck_supported?` — `deck_collection.present?`.

Why in the registry: it is the single place that already knows per-type facts (M3), and `EntitySync` already computes the same identities (`logical_key`), so YAML identity and read-model identity cannot drift.

- [ ] **Step 1: Write the failing spec**

Read the top of `spec/services/kong/entity_types_spec.rb` first and use whatever `described_class` / structure it already has. Append inside its outer `RSpec.describe`, before the final `end`:

```ruby
  describe "decK facts (M5c)" do
    it "describes every type that is rendered into decK YAML" do
      expected = {
        "service" => [ "services", "name", [] ],
        "route" => [ "routes", "name", %w[service] ],
        "consumer" => [ "consumers", "username", [] ],
        "plugin" => [ "plugins", "name", %w[service route consumer] ],
        "upstream" => [ "upstreams", "name", [] ],
        "target" => [ "targets", "target", %w[upstream] ],
        "certificate" => [ "certificates", "id", [] ],
        "sni" => [ "snis", "name", %w[certificate] ],
        "ca_certificate" => [ "ca_certificates", "id", [] ]
      }

      expected.each do |type, (collection, key, refs)|
        definition = Kong::EntityTypes.fetch(type)

        expect([ definition.deck_collection, definition.deck_key, definition.deck_refs ]).to eq([ collection, key, refs ]), "wrong decK facts for #{type}"
        expect(definition).to be_deck_supported
      end
    end

    it "never renders a credential (docs/DESIGN.md 1.7: decK would sync password hashes back and break logins)" do
      %w[keyauth_credential basicauth_credential].each do |type|
        definition = Kong::EntityTypes.fetch(type)

        expect(definition).not_to be_deck_supported
        expect(definition.deck_refs).to eq([])
      end
    end

    it "leaves no registered type undecided, so a new type has to choose" do
      undecided = Kong::EntityTypes::DEFINITIONS.reject do |type, definition|
        definition.deck_supported? || %w[keyauth_credential basicauth_credential].include?(type)
      end

      expect(undecided.keys).to eq([])
    end
  end
```

- [ ] **Step 2: Run and confirm the right failure**

Run: `bundle exec rspec -r "$K" spec/services/kong/entity_types_spec.rb`

Expected: the three new examples FAIL with `NoMethodError: undefined method 'deck_collection'` (and `deck_supported?`).

- [ ] **Step 3: Implement — the struct**

In `app/services/kong/entity_types.rb`, replace the `Definition = Struct.new(...) do` opening (the member list) with:

```ruby
    Definition = Struct.new(:list_path, :parent_type, :create_path_proc, :nested_collection_proc, :schema_name,
                             :parent_in_body, :deck_collection, :deck_key, :deck_refs, keyword_init: true) do
      # M5c. Where an entity of this type lives in decK YAML, what identifies
      # it there, and which Kong-JSON fields point at the parent it is nested
      # inside (dropped when rendering: decK wants the nesting, not the ref).
      # A type with no `deck_collection` is never rendered.
      def deck_supported?
        deck_collection.present?
      end

      def deck_refs
        self[:deck_refs] || []
      end

```

(Keep every existing method — `nested?`, `requires_parent?`, `collection_path`, `member_path`, `create_path`, `require_parent!` — exactly as they are, after the new methods.)

- [ ] **Step 4: Implement — the definitions**

Replace the whole `DEFINITIONS = { ... }.freeze` block (from `DEFINITIONS = {` down to `}.freeze`, keeping every existing comment) with:

```ruby
    DEFINITIONS = {
      "service" => Definition.new(list_path: "/services", parent_type: nil, deck_collection: "services", deck_key: "name"),
      "route" => Definition.new(list_path: "/routes", parent_type: "service", deck_collection: "routes", deck_key: "name",
                                 deck_refs: %w[service]),
      "consumer" => Definition.new(list_path: "/consumers", parent_type: nil, deck_collection: "consumers", deck_key: "username"),
      # Global `/key-auths` and `/basic-auths` list/get/patch/delete any
      # credential by id; creation needs a specific consumer to attach to,
      # hence the nested create_path_proc. No deck_collection: a credential is
      # never rendered into decK YAML (docs/DESIGN.md section 1.7).
      "keyauth_credential" => Definition.new(
        list_path: "/key-auths", parent_type: "consumer",
        create_path_proc: ->(parent_kong_id) { "/consumers/#{parent_kong_id}/key-auth" }
      ),
      "basicauth_credential" => Definition.new(
        list_path: "/basic-auths", parent_type: "consumer",
        create_path_proc: ->(parent_kong_id) { "/consumers/#{parent_kong_id}/basic-auth" }
      ),
      # Kong's `POST /plugins` is flat regardless of scope -- the target
      # (service/route/consumer, or none for global) goes *in the body*, not
      # in the path, so no create_path_proc is needed the way credentials
      # need one. `parent_type: nil` here is deliberate, not "no parent
      # like service/consumer": a plugin's scope varies per row (global, or
      # attached to any of three different types), so the registry has no
      # single fixed answer the way every other type does -- see
      # Kong::EntitySync#identify's "plugin" branch, which resolves it per
      # instance instead. decK nests it under whichever of the three it is
      # scoped to (Kong::DeckRenderer resolves that per plan).
      "plugin" => Definition.new(list_path: "/plugins", parent_type: nil, deck_collection: "plugins", deck_key: "name",
                                  deck_refs: %w[service route consumer]),
      "upstream" => Definition.new(list_path: "/upstreams", parent_type: nil, schema_name: "upstreams",
                                    deck_collection: "upstreams", deck_key: "name"),
      # Kong 3.7 targets are ordinary mutable entities (PATCH/DELETE work,
      # duplicates 409), but there is no global collection -- everything
      # lives under the upstream, so `nested_collection_proc` and no list_path.
      # decK accepts a target only nested under its upstream (top-level
      # `targets:` is rejected -- measured, M5c).
      "target" => Definition.new(
        parent_type: "upstream",
        nested_collection_proc: ->(upstream_kong_id) { "/upstreams/#{upstream_kong_id}/targets" },
        schema_name: "targets", deck_collection: "targets", deck_key: "target", deck_refs: %w[upstream]
      ),
      # M5b. All three are flat top-level collections in Kong 3.7 -- unlike a
      # target, an SNI is listable and addressable without its certificate.
      # In decK YAML a certificate is identified by `id` (decK requires it on
      # certificates, and only there), an SNI nests under it, and a CA
      # certificate matches by `id` when present, else by its cert text.
      "certificate" => Definition.new(list_path: "/certificates", parent_type: nil, schema_name: "certificates",
                                       deck_collection: "certificates", deck_key: "id"),
      "sni" => Definition.new(list_path: "/snis", parent_type: "certificate", schema_name: "snis", parent_in_body: true,
                               deck_collection: "snis", deck_key: "name", deck_refs: %w[certificate]),
      "ca_certificate" => Definition.new(list_path: "/ca_certificates", parent_type: nil, schema_name: "ca_certificates",
                                          deck_collection: "ca_certificates", deck_key: "id")
    }.freeze
```

- [ ] **Step 5: Run to green, RuboCop, whole suite**

Run: `bundle exec rspec -r "$K" spec/services/kong/entity_types_spec.rb` — all PASS.
Run: `bundle exec rubocop app/services/kong/entity_types.rb spec/services/kong/entity_types_spec.rb` — no offenses.
Run: `bundle exec rspec -r "$K"` — 0 failures.

- [ ] **Step 6: Commit**

```bash
git add app/services/kong/entity_types.rb spec/services/kong/entity_types_spec.rb
git commit -m "feat(m5c): registry knows each type's decK collection, identity and parent refs" -m "Credentials deliberately have none, so they are never rendered." -m "Co-Authored-By: Claude Sonnet 5 <noreply@anthropic.com>"
```

---

### Task 4: `Kong::DeckDocument` — the decK file format, with the fail-closed input guard

**Files:**
- Create: `app/services/kong/deck_document.rb`
- Create: `spec/services/kong/deck_document_spec.rb`

**Interfaces:**
- Consumes: `Kong::ChangeGuardrails::Violation`.
- Produces:
  - `Kong::DeckDocument.parse(text, select_tags:)` → Hash. `text` may be nil/blank. Sets `_format_version` (default `"3.0"`), `_info`, and **overwrites** `_info.select_tags` from the caller (rule ข). Adds **no** collection keys. Keeps every key it is given, managed or not.
  - `Kong::DeckDocument.serialize(doc)` → String. Deterministic; writes every managed collection nested, then unmanaged keys sorted; leaves out an empty managed collection.
  - `Kong::DeckDocument.verify_input!(text)` → `nil`, or raises `Kong::DeckDocument::Unparseable` (a `Kong::ChangeGuardrails::Violation`) when `serialize(parse(text)) != text`, naming the first differing line. Blank text passes.
  - `Kong::DeckDocument::Unparseable`.

Why it exists: today's `serialize` emits only `_format_version`, `_info` and `services`, silently dropping every other collection — and `verify_round_trip!` compares its own truncated output against itself, so it can never fail. Since `deck gateway sync` deletes anything absent from the file, that would propose deleting a repo's routes, upstreams and consumers. The guard must run on the **input**.

This is the prototype that passed 30/30 against real decK 1.51.1 and 1.66.1 (round-trip fixed point, decK accepts the output, foreign keys survive, hand-formatted/commented/unparseable input refused, placeholder single-quoted, PEM as a literal block, long strings unfolded).

- [ ] **Step 1: Write the failing spec**

Create `spec/services/kong/deck_document_spec.rb`:

```ruby
require "rails_helper"

RSpec.describe Kong::DeckDocument do
  let(:tags) { [ "managed-by-kongctl", "team-payments" ] }
  let(:pem) { "-----BEGIN CERTIFICATE-----\nAAAA\nBBBB\n-----END CERTIFICATE-----\n" }

  # Every managed type once, nested as decK wants, plus a key the tool does not manage.
  def full_document
    doc = described_class.parse(nil, select_tags: tags)
    doc["services"] = [ {
      "url" => "http://payments:8080", "name" => "payments-api", "tags" => [ "payment" ], "enabled" => true,
      "routes" => [ { "paths" => [ "/pay" ], "name" => "pay-route", "strip_path" => true,
                      "plugins" => [ { "name" => "rate-limiting", "config" => { "policy" => "local", "minute" => 60 } } ] } ],
      "plugins" => [ { "name" => "correlation-id" } ]
    } ]
    doc["upstreams"] = [ { "name" => "orders-up", "targets" => [ { "weight" => 100, "target" => "10.0.0.1:80" } ] } ]
    doc["certificates"] = [
      { "cert" => pem, "id" => "11111111-2222-3333-4444-555555555555", "key" => "{vault://env/cert-pay-key}",
        "snis" => [ { "name" => "pay.example.internal" } ], "tags" => [ "payment" ] },
      { "cert" => "-----BEGIN CERTIFICATE-----\nCCCC\n-----END CERTIFICATE-----\n", "id" => "66666666-7777-8888-9999-000000000000",
        "key" => %q(${{ env "DECK_CERT_OTHER_KEY" }}) }
    ]
    doc["consumers"] = [ { "username" => "reporting-bot", "tags" => [] } ]
    doc["vaults"] = [ { "name" => "env", "prefix" => "env" } ]
    doc
  end

  let(:golden) do
    <<~YAML
      _format_version: '3.0'
      _info:
        select_tags:
          - managed-by-kongctl
          - team-payments
      services:
        - name: payments-api
          enabled: true
          plugins:
            - name: correlation-id
          routes:
            - name: pay-route
              paths:
                - "/pay"
              plugins:
                - name: rate-limiting
                  config:
                    minute: 60
                    policy: local
              strip_path: true
          tags:
            - payment
          url: http://payments:8080
      upstreams:
        - name: orders-up
          targets:
            - target: 10.0.0.1:80
              weight: 100
      certificates:
        - id: 11111111-2222-3333-4444-555555555555
          cert: |
            -----BEGIN CERTIFICATE-----
            AAAA
            BBBB
            -----END CERTIFICATE-----
          key: "{vault://env/cert-pay-key}"
          snis:
            - name: pay.example.internal
          tags:
            - payment
        - id: 66666666-7777-8888-9999-000000000000
          cert: |
            -----BEGIN CERTIFICATE-----
            CCCC
            -----END CERTIFICATE-----
          key: '${{ env "DECK_CERT_OTHER_KEY" }}'
      consumers:
        - username: reporting-bot
          tags: []
      vaults:
        - name: env
          prefix: env
    YAML
  end

  describe ".parse" do
    it "builds a skeleton with no collections when there is no YAML yet" do
      expect(described_class.parse(nil, select_tags: [ "managed-by-kongctl" ])).to eq(
        "_format_version" => "3.0",
        "_info" => { "select_tags" => [ "managed-by-kongctl" ] }
      )
    end

    it "always overwrites select_tags from the connection, even if the file disagrees (rule ข -- mandatory)" do
      doc = described_class.parse("_info:\n  select_tags:\n    - stale-tag\n", select_tags: [ "managed-by-kongctl" ])

      expect(doc["_info"]["select_tags"]).to eq([ "managed-by-kongctl" ])
    end

    it "keeps every key it is given, including ones the tool does not manage" do
      doc = described_class.parse("routes:\n  - name: r\nvaults:\n  - name: env\nconsumer_groups:\n  - name: gold\n", select_tags: [])

      expect(doc.keys).to include("routes", "vaults", "consumer_groups")
    end

    it "raises Unparseable, a guardrail Violation, for text that is not YAML" do
      expect { described_class.parse("services: [unclosed\n", select_tags: []) }
        .to raise_error(described_class::Unparseable, /can't be parsed/) { |error| expect(error).to be_a(Kong::ChangeGuardrails::Violation) }
    end
  end

  describe ".serialize" do
    it "writes the exact bytes for every managed type, nested, with unmanaged keys after" do
      expect(described_class.serialize(full_document)).to eq(golden)
    end

    it "is a fixed point: serialize(parse(serialize(doc))) == serialize(doc)" do
      first = described_class.serialize(full_document)

      expect(described_class.serialize(described_class.parse(first, select_tags: tags))).to eq(first)
    end

    it "leaves out an empty managed collection, since decK rejects a bare `services:` (null)" do
      doc = described_class.parse(nil, select_tags: tags)
      doc["services"] = []
      doc["consumers"] = nil

      expect(described_class.serialize(doc)).to eq("_format_version: '3.0'\n_info:\n  select_tags:\n    - managed-by-kongctl\n    - team-payments\n")
    end

    it "writes the decK env placeholder single-quoted -- the one form decK and a YAML parser both accept" do
      out = described_class.serialize(full_document)

      expect(out).to include(%q(key: '${{ env "DECK_CERT_OTHER_KEY" }}'))
      expect(YAML.safe_load(out)["certificates"][1]["key"]).to eq(%q(${{ env "DECK_CERT_OTHER_KEY" }}))
    end

    it "writes a PEM as a literal block that comes back identical" do
      out = described_class.serialize(full_document)

      expect(out).to include("cert: |\n      -----BEGIN CERTIFICATE-----")
      expect(YAML.safe_load(out)["certificates"][0]["cert"]).to eq(pem)
    end

    it "writes an identity key first, then the rest alphabetically" do
      doc = described_class.parse(nil, select_tags: [])
      doc["services"] = [ { "url" => "http://a", "enabled" => true, "name" => "a" } ]

      expect(described_class.serialize(doc)).to include("services:\n  - name: a\n    enabled: true\n    url: http://a\n")
    end

    it "never folds a long string across lines" do
      doc = described_class.parse(nil, select_tags: [])
      long = "/a b/#{'x' * 200}"
      doc["services"] = [ { "name" => "s", "path" => long } ]

      out = described_class.serialize(doc)

      expect(out.lines.grep(/path:/).size).to eq(1)
      expect(YAML.safe_load(out)["services"][0]["path"]).to eq(long)
    end

    it "keeps scalar types, including strings that look like other types" do
      doc = described_class.parse(nil, select_tags: [])
      doc["services"] = [ { "name" => "s", "port" => 8080, "enabled" => true, "retries" => 5, "tags" => [ "a", "true", "10", "yes: no" ] } ]

      back = YAML.safe_load(described_class.serialize(doc))["services"][0]

      expect(back).to include("port" => 8080, "enabled" => true, "retries" => 5, "tags" => [ "a", "true", "10", "yes: no" ])
    end
  end

  describe ".verify_input!" do
    it "passes when there is no file yet" do
      expect(described_class.verify_input!(nil)).to be_nil
      expect(described_class.verify_input!("")).to be_nil
    end

    it "passes the tool's own output" do
      expect(described_class.verify_input!(golden)).to be_nil
    end

    it "tolerates the bare `services:` the tool wrote before M5c (decK itself rejects that line; the re-render drops it)" do
      legacy = "_format_version: '3.0'\n_info:\n  select_tags:\n    - managed-by-kongctl\nservices:\n"

      expect(described_class.verify_input!(legacy)).to be_nil
      expect(described_class.serialize(described_class.parse(legacy, select_tags: [ "managed-by-kongctl" ]))).not_to include("services")
    end

    it "refuses hand-formatted YAML, naming the first line that would change" do
      hand = "_format_version: '3.0'\n_info:\n  select_tags: [team-a]\nservices:\n  - {name: orders, url: 'http://orders:80'}\n"

      expect { described_class.verify_input!(hand) }
        .to raise_error(described_class::Unparseable, /would not survive a re-render unchanged \(first difference at line \d+\)/)
    end

    it "refuses a file with a comment, which a re-render would silently delete" do
      expect { described_class.verify_input!("# owned by team-a\n#{golden}") }.to raise_error(described_class::Unparseable)
    end

    it "refuses YAML anchors and aliases" do
      anchored = "_format_version: '3.0'\n_info:\n  select_tags: []\nservices:\n  - &s\n    name: a\n  - *s\n"

      expect { described_class.verify_input!(anchored) }.to raise_error(described_class::Unparseable)
    end

    it "refuses text that is not YAML at all" do
      expect { described_class.verify_input!("services: [unclosed\n") }.to raise_error(described_class::Unparseable, /can't be parsed/)
    end

    it "regression (spec 1.6): collections the tool does not manage survive an edit instead of being dropped" do
      text = described_class.serialize(described_class.parse(<<~YAML, select_tags: tags))
        _format_version: '3.0'
        _info:
          select_tags:
            - managed-by-kongctl
            - team-payments
        consumer_groups:
          - name: gold-tier
        routes:
          - name: flat-route
        vaults:
          - name: env
            prefix: env
      YAML
      described_class.verify_input!(text)

      doc = described_class.parse(text, select_tags: tags)
      doc["services"] = [ { "name" => "new-service" } ]
      out = described_class.serialize(doc)

      expect(out).to include("consumer_groups:", "gold-tier", "routes:", "flat-route", "vaults:", "new-service")
    end
  end
end
```

- [ ] **Step 2: Run and confirm the right failure**

Run: `bundle exec rspec -r "$K" spec/services/kong/deck_document_spec.rb`

Expected: every example FAILS with `NameError: uninitialized constant Kong::DeckDocument`.

- [ ] **Step 3: Implement**

Create `app/services/kong/deck_document.rb`:

```ruby
module Kong
  # The decK state file: parse, deterministic serialize, and the fail-closed
  # guard on the input -- docs/DESIGN.md section 6's iron rules:
  #   ก. always build the YAML from git, never from `deck gateway dump`
  #   ข. `_info.select_tags` is mandatory (deck gateway sync deletes anything
  #      untagged)
  #   ค. serialize(parse(x)) == x, byte for byte
  # Every format decision below was measured against decK 1.51.1 and 1.66.1
  # (docs/superpowers/specs/2026-09-21-m5c-deck-rendering-design.md section 1).
  class DeckDocument
    # The file would not survive a re-render unchanged (or is not YAML). A
    # guardrail refusal like any other, so it surfaces as one (403 / redirect).
    class Unparseable < Kong::ChangeGuardrails::Violation; end

    FORMAT_VERSION = "3.0"
    # The collections the tool manages, in the order they are written. Anything
    # else the file holds (vaults, consumer_groups, flat routes, ...) follows,
    # sorted, and is kept verbatim: decK's schema is closed, so what it accepts
    # is decK's call -- `deck file validate` decides, not this class.
    COLLECTION_ORDER = %w[services upstreams certificates ca_certificates consumers plugins].freeze
    # Written first inside any mapping, so an entity reads by what names it.
    IDENTITY_KEYS = %w[name username target id].freeze
    DECK_ENV_REFERENCE = /\A\$\{\{ env "DECK_[A-Z0-9_]+" \}\}\z/

    # Builds the working document. `text` is nil/blank the first time a
    # connection's config repo has no file yet. Adds no collection keys.
    def self.parse(text, select_tags:)
      doc = text.present? ? YAML.safe_load(text) : {}
      doc = {} unless doc.is_a?(Hash)
      doc["_format_version"] ||= FORMAT_VERSION
      doc["_info"] = doc["_info"].is_a?(Hash) ? doc["_info"] : {}
      doc["_info"]["select_tags"] = Array(select_tags)
      doc
    rescue Psych::Exception => e
      raise Unparseable, "the config YAML can't be parsed (#{e.class})"
    end

    # Rule ค, applied to the INPUT. If a re-render would not reproduce the file,
    # it would silently rewrite or drop part of it -- and `deck gateway sync`
    # deletes whatever is absent -- so refuse before anything is written.
    def self.verify_input!(text)
      return if text.blank?

      rendered = serialize(parse(text, select_tags: file_select_tags(text)))
      return if rendered == text || rendered == without_legacy_empty_collections(text)

      raise Unparseable, "the config YAML would not survive a re-render unchanged (#{first_difference(text, rendered)}) " \
        "-- comments, anchors and hand formatting can't be preserved; rewrite it in the tool's format first"
    end

    def self.serialize(doc)
      lines = [ "_format_version: #{scalar(doc.fetch('_format_version', FORMAT_VERSION))}", "_info:", "  select_tags:" ]
      Array(doc.dig("_info", "select_tags")).each { |tag| lines << "    - #{scalar(tag)}" }
      top_level_keys(doc).each { |key| lines.concat(entry_lines(key, doc[key], 0)) }
      "#{lines.join("\n")}\n"
    end

    # An empty managed collection is left out: decK rejects a bare `services:`
    # (null), and Kong has nothing to sync for it anyway.
    def self.top_level_keys(doc)
      rest = (doc.keys - %w[_format_version _info]).reject { |key| COLLECTION_ORDER.include?(key) && doc[key].blank? }
      known = COLLECTION_ORDER & rest
      known + (rest - known).sort
    end
    private_class_method :top_level_keys

    # One `key: value` entry at `indent` columns, whatever the value is.
    def self.entry_lines(key, value, indent)
      pad = " " * indent
      case value
      when Array then array_lines(key, value, indent)
      when Hash
        return [ "#{pad}#{key}: {}" ] if value.empty?

        [ "#{pad}#{key}:" ] + mapping_lines(value, indent + 2)
      when String
        value.include?("\n") ? block_lines(key, value, indent) : [ "#{pad}#{key}: #{scalar(value)}" ]
      else
        [ "#{pad}#{key}: #{scalar(value)}" ]
      end
    end
    private_class_method :entry_lines

    def self.mapping_lines(hash, indent)
      ordered_keys(hash).flat_map { |key| entry_lines(key, hash[key], indent) }
    end
    private_class_method :mapping_lines

    def self.array_lines(key, items, indent)
      pad = " " * indent
      return [ "#{pad}#{key}: []" ] if items.empty?

      lines = [ "#{pad}#{key}:" ]
      items.each do |item|
        if item.is_a?(Hash) && item.any?
          body = mapping_lines(item, indent + 4)
          lines << "#{pad}  - #{body.first.lstrip}"
          lines.concat(body.drop(1))
        else
          lines << "#{pad}  - #{item.is_a?(Hash) ? '{}' : scalar(item)}"
        end
      end
      lines
    end
    private_class_method :array_lines

    # A multi-line string (a PEM) as a literal block, so it stays readable and
    # round-trips exactly. Falls back to a quoted scalar when a block cannot
    # hold it faithfully (leading whitespace, several trailing newlines).
    def self.block_lines(key, value, indent)
      pad = " " * indent
      body = value.delete_suffix("\n")
      faithful = !body.end_with?("\n") && body.lines.none? { |line| line.start_with?(" ") || line.start_with?("\t") }
      return [ "#{pad}#{key}: #{scalar(value)}" ] unless faithful

      chomp = value.end_with?("\n") ? "|" : "|-"
      [ "#{pad}#{key}: #{chomp}" ] + body.split("\n", -1).map { |line| line.empty? ? "" : "#{pad}  #{line}" }
    end
    private_class_method :block_lines

    def self.ordered_keys(hash)
      first = IDENTITY_KEYS.select { |key| hash.key?(key) }
      first + (hash.keys - first).sort_by(&:to_s)
    end
    private_class_method :ordered_keys

    # decK substitutes its env placeholder as TEXT before it parses YAML, so the
    # reference must reach the file exactly as decK expects it: in single quotes
    # (the one form both decK and a YAML parser accept -- measured, M5c).
    # `line_width: -1` stops Psych folding a long value across lines.
    def self.scalar(value)
      return "null" if value.nil?
      return "'#{value}'" if value.is_a?(String) && DECK_ENV_REFERENCE.match?(value)

      YAML.dump(value, line_width: -1).delete_prefix("---").strip
    end
    private_class_method :scalar

    # Before M5c the tool wrote a bare `services:` for an empty file -- a line
    # decK itself rejects (it was never validated: DeckCli was stubbed). The
    # re-render drops it; that is the one difference from a file the tool wrote
    # that the guard must not treat as data loss.
    def self.without_legacy_empty_collections(text)
      text.gsub(/^(?:#{COLLECTION_ORDER.join('|')}):[ \t]*\r?\n/, "")
    end
    private_class_method :without_legacy_empty_collections

    # The file's own tags, so the guard compares like with like: parse would
    # otherwise overwrite them and a stale tag list would read as data loss.
    def self.file_select_tags(text)
      Array(YAML.safe_load(text).then { |doc| doc.is_a?(Hash) ? doc.dig("_info", "select_tags") : nil })
    rescue Psych::Exception
      []
    end
    private_class_method :file_select_tags

    def self.first_difference(original, rendered)
      a = original.lines
      b = rendered.lines
      index = (0...[ a.size, b.size ].max).find { |i| a[i] != b[i] }
      index ? "first difference at line #{index + 1}" : "trailing whitespace differs"
    end
    private_class_method :first_difference
  end
end
```

- [ ] **Step 4: Run to green, RuboCop, whole suite**

Run: `bundle exec rspec -r "$K" spec/services/kong/deck_document_spec.rb` — all PASS.
If the golden example fails, print the actual output and compare byte-for-byte; the expected text in the spec is real output of this implementation, so a mismatch means a transcription slip, not a design question.
Run: `bundle exec rubocop app/services/kong/deck_document.rb spec/services/kong/deck_document_spec.rb` — no offenses.
Run: `bundle exec rspec -r "$K"` — 0 failures (the old `DeckRenderer.parse/serialize` still exist and are untouched).

- [ ] **Step 5: Prove it against the real decK binary**

This is the check the prototype passed; repeat it on the real class. Write `<scratchpad>/verify_deck_document.rb` (with the Write tool):

```ruby
# Run with: bin/rails runner <path>   (RAILS_ENV=test, DATABASE_URL as in the plan header)
require "open3"
require "tmpdir"

bins = ENV.fetch("DECK_BINS").split(",")   # e.g. ".../deck1511/deck.exe,.../deck1661/deck.exe"
doc = Kong::DeckDocument.parse(nil, select_tags: [ "team-a" ])
doc["services"] = [ { "name" => "orders", "url" => "http://orders:80", "routes" => [ { "name" => "r", "paths" => [ "/o" ] } ] } ]
doc["upstreams"] = [ { "name" => "up", "targets" => [ { "target" => "10.0.0.1:80" } ] } ]
doc["vaults"] = [ { "name" => "env", "prefix" => "env" } ]
text = Kong::DeckDocument.serialize(doc)

Dir.mktmpdir do |dir|
  path = File.join(dir, "kong.yaml")
  File.write(path, text)
  bins.each do |bin|
    _o, e, st = Open3.capture3(bin, "file", "validate", path)
    puts "#{st.success? ? 'PASS' : 'FAIL'} #{File.basename(File.dirname(bin))}#{st.success? ? '' : " -- #{e.lines.first}"}"
  end
end
puts(Kong::DeckDocument.serialize(Kong::DeckDocument.parse(text, select_tags: [ "team-a" ])) == text ? "PASS fixed point" : "FAIL not a fixed point")
```

Run: `DECK_BINS="$SP/deck1511/deck.exe,$SP/deck1661/deck.exe" RAILS_ENV=test bin/rails runner <that path> 2>&1 | grep -vE "warning: |fiddle"`

Expected: `PASS deck1511`, `PASS deck1661`, `PASS fixed point`. Any FAIL is a real finding: stop and report it.

- [ ] **Step 6: Commit**

Normalise both new files to CRLF, then:

```bash
git add app/services/kong/deck_document.rb spec/services/kong/deck_document_spec.rb
git commit -m "feat(m5c): DeckDocument owns the decK file format and refuses input it can't reproduce" -m "Generalises parse/serialize from one hardcoded services list to every managed collection, nested, and keeps unmanaged keys (vaults, consumer_groups, flat routes) verbatim. verify_input! checks the INPUT round-trips -- the old check compared its own truncated output with itself and so could never catch a dropped collection. Verified against decK 1.51.1 and 1.66.1." -m "Co-Authored-By: Claude Sonnet 5 <noreply@anthropic.com>"
```

---

### Task 5: `Kong::DeckRenderer.apply_change` places every managed type

**Files:**
- Create: `app/services/kong/deck_read_model_resolver.rb`, `spec/services/kong/deck_read_model_resolver_spec.rb`
- Modify: `app/services/kong/deck_renderer.rb`, `spec/services/kong/deck_renderer_spec.rb`

**Interfaces:**
- Consumes: `Kong::EntityTypes` decK facts (Task 3): `deck_supported?`, `deck_collection`, `deck_key`, `deck_refs`. `Kong::DeckDocument` (Task 4) for its output shape. `ChangePlan#before/after/operation/entity_type/target_kong_id/parent_kong_id`.
- Produces:
  - `Kong::DeckRenderer.apply_change(doc, change_plan, resolver: Kong::DeckReadModelResolver.new(change_plan.kong_connection))` → `doc`, mutated in place. Same call the applier already makes, so `ChangeApplier` needs no change for it.
  - `Kong::DeckRenderer.assert_supported!(entity_type)` → raises `NotImplementedError` (deliberate, worded as such) for a type with no decK collection.
  - `Kong::DeckRenderer::Unrenderable < Kong::ChangeGuardrails::Violation`.
  - `Kong::DeckReadModelResolver.new(connection)` with `#name_of(kong_id)` and `#parent_of(kong_id)`, both `nil` for anything the read-model does not hold.
  - Side effect, deliberate and documented: rendering a certificate **create** assigns a fresh UUID to `change_plan.target_kong_id` (in memory; the applier's `update!` persists it).

Placement rules (spec §4): service/upstream/certificate/ca_certificate/consumer are top-level lists; `route` under `services[].routes[]`; `target` under `upstreams[].targets[]`; `sni` under `certificates[].snis[]`; a `plugin` under its scope's `plugins[]` (a route-scoped plugin goes under `services[].routes[].plugins[]`), or top-level when global. What renders: no `null`, no `created_at`/`updated_at`, no `id` (except a certificate's), no parent reference. A certificate's `snis` (Kong returns names) become `[{name: …}]`.

This is the prototype that passed 16/16 against real decK 1.51.1 and 1.66.1, fed with **real Kong JSON** (a real service, route, consumer and plugin read from the local Kong; Kong-3.7-shaped JSON for the rest): all nine types rendered, decK accepted the result, the output was a fixed point, and each fail-closed case refused.

Findings that shaped it (measured): decK **rejects `null`** (`consumers.0.custom_id: Invalid type. Expected: string, given: null`) and Kong returns `null` constantly, so nulls are stripped; a nested plugin's `route: {id}` is rejected (`Expected: string, given: object`), so parent references are dropped; ids and timestamps are tolerated but noisy.

- [ ] **Step 1: Write the resolver's failing spec**

Create `spec/services/kong/deck_read_model_resolver_spec.rb`:

```ruby
require "rails_helper"

RSpec.describe Kong::DeckReadModelResolver do
  let(:connection) { create(:kong_connection) }
  let(:other_connection) { create(:kong_connection) }
  let(:svc_id) { "aaaaaaaa-0000-0000-0000-000000000001" }
  let(:route_id) { "aaaaaaaa-0000-0000-0000-000000000002" }

  before do
    create(:kong_entity, kong_connection: connection, entity_type: "service", kong_id: svc_id, name: "orders")
    create(:kong_entity, kong_connection: connection, entity_type: "route", kong_id: route_id, name: "orders-route",
      parent_type: "service", parent_kong_id: svc_id)
  end

  subject(:resolver) { described_class.new(connection) }

  it "names an entity the way decK YAML does" do
    expect(resolver.name_of(svc_id)).to eq("orders")
  end

  it "finds the parent of a child" do
    expect(resolver.parent_of(route_id)).to eq(svc_id)
  end

  it "answers nil for an id the read-model does not hold, or that is not an id at all" do
    expect(resolver.name_of("aaaaaaaa-0000-0000-0000-00000000ffff")).to be_nil
    expect(resolver.name_of("not-a-uuid")).to be_nil
    expect(resolver.name_of(nil)).to be_nil
    expect(resolver.parent_of("")).to be_nil
  end

  it "never answers for another connection's entity" do
    expect(described_class.new(other_connection).name_of(svc_id)).to be_nil
  end

  it "ignores a soft-deleted entity" do
    KongEntity.find_by!(kong_id: svc_id).update!(deleted_at: Time.current)

    expect(resolver.name_of(svc_id)).to be_nil
  end

  it "copes with no connection at all" do
    expect(described_class.new(nil).name_of(svc_id)).to be_nil
  end
end
```

- [ ] **Step 2: Write the renderer's failing spec**

In `spec/services/kong/deck_renderer_spec.rb`, replace the whole `describe ".apply_change" do … end` block (it ends just before `describe ".serialize" do`) with the block below. Leave `describe ".parse"` and `describe ".serialize"` exactly as they are: Task 6 removes those methods and their specs.

```ruby
  describe ".apply_change" do
    let(:svc_id) { "aaaaaaaa-0000-0000-0000-000000000001" }
    let(:route_id) { "aaaaaaaa-0000-0000-0000-000000000002" }
    let(:up_id) { "aaaaaaaa-0000-0000-0000-000000000003" }
    let(:con_id) { "aaaaaaaa-0000-0000-0000-000000000004" }
    let(:cert_id) { "11111111-2222-3333-4444-555555555555" }
    let(:pem) { "-----BEGIN CERTIFICATE-----\nAAAA\nBBBB\n-----END CERTIFICATE-----\n" }
    let(:doc) { Kong::DeckDocument.parse(nil, select_tags: []) }

    let(:resolver) do
      names = { svc_id => "orders", route_id => "orders-route", up_id => "orders-up", con_id => "reporting-bot" }
      parents = { route_id => svc_id }
      instance_double(Kong::DeckReadModelResolver).tap do |double|
        allow(double).to receive(:name_of) { |id| names[id] }
        allow(double).to receive(:parent_of) { |id| parents[id] }
      end
    end

    def plan(entity_type:, operation:, before: {}, after: {}, target_kong_id: nil, parent_kong_id: nil)
      ChangePlan.new(entity_type: entity_type, operation: operation, before: before, after: after,
        target_kong_id: target_kong_id, parent_kong_id: parent_kong_id)
    end

    def render_change(**args)
      described_class.apply_change(doc, plan(**args), resolver: resolver)
    end

    describe "services" do
      it "appends a new service on create, leaving out Kong's bookkeeping and nulls" do
        render_change(entity_type: "service", operation: "create",
          after: { "id" => "abc", "created_at" => 1, "updated_at" => 2, "name" => "payments-api", "tags" => [ "payment" ], "client_certificate" => nil })

        expect(doc["services"]).to eq([ { "name" => "payments-api", "tags" => [ "payment" ] } ])
      end

      it "merges attributes into the matched service on update, and a field set to null is removed" do
        doc["services"] = [ { "name" => "payments-api", "tags" => [ "payment" ], "enabled" => true, "path" => "/old" } ]

        render_change(entity_type: "service", operation: "update", before: { "name" => "payments-api" },
          after: { "id" => "abc", "name" => "payments-api", "tags" => %w[payment deprecated], "enabled" => true, "path" => nil })

        expect(doc["services"]).to eq([ { "name" => "payments-api", "tags" => %w[payment deprecated], "enabled" => true } ])
      end

      it "removes the matched service on delete" do
        doc["services"] = [ { "name" => "payments-api" }, { "name" => "keep-me" } ]

        render_change(entity_type: "service", operation: "delete", before: { "name" => "payments-api" })

        expect(doc["services"]).to eq([ { "name" => "keep-me" } ])
      end

      it "refuses rather than silently no-op when the update target isn't in the YAML" do
        expect {
          render_change(entity_type: "service", operation: "update", before: { "name" => "missing" }, after: { "name" => "missing" })
        }.to raise_error(Kong::DeckRenderer::Unrenderable, /no service with name missing in this YAML/)
      end

      it "refuses to create a service that is already there" do
        doc["services"] = [ { "name" => "orders" } ]

        expect { render_change(entity_type: "service", operation: "create", after: { "name" => "orders" }) }
          .to raise_error(Kong::DeckRenderer::Unrenderable, /service orders is already in this YAML/)
      end

      it "raises a Violation subclass, so a refusal surfaces as one rather than a 500" do
        expect { render_change(entity_type: "service", operation: "delete", before: { "name" => "nope" }) }
          .to raise_error(Kong::ChangeGuardrails::Violation)
      end
    end

    describe "routes" do
      before { doc["services"] = [ { "name" => "orders", "url" => "http://orders:80" } ] }

      it "nests a route under its service, dropping the reference to it and any nulls" do
        render_change(entity_type: "route", operation: "create",
          after: { "name" => "orders-route", "paths" => [ "/o" ], "hosts" => nil, "service" => { "id" => svc_id } })

        expect(doc["services"][0]["routes"]).to eq([ { "name" => "orders-route", "paths" => [ "/o" ] } ])
      end

      it "refuses an unnamed route: decK requires a name although Kong's Admin API does not" do
        expect {
          render_change(entity_type: "route", operation: "create", after: { "paths" => [ "/o" ], "service" => { "id" => svc_id } })
        }.to raise_error(Kong::DeckRenderer::Unrenderable, /a route needs a name to be written into decK YAML/)
      end

      it "refuses a route whose service is not in the YAML, since nesting leaves it nowhere to go" do
        doc["services"] = []

        expect {
          render_change(entity_type: "route", operation: "create", after: { "name" => "r", "service" => { "id" => svc_id } })
        }.to raise_error(Kong::DeckRenderer::Unrenderable, /the service orders isn't in this YAML/)
      end

      it "refuses a route whose service the read-model cannot name" do
        expect {
          render_change(entity_type: "route", operation: "create",
            after: { "name" => "r", "service" => { "id" => "aaaaaaaa-0000-0000-0000-00000000ffff" } })
        }.to raise_error(Kong::DeckRenderer::Unrenderable, /can't tell which service this belongs to/)
      end

      it "finds the route to update or delete through its service" do
        doc["services"][0]["routes"] = [ { "name" => "orders-route", "paths" => [ "/o" ] } ]

        render_change(entity_type: "route", operation: "update", before: { "name" => "orders-route", "service" => { "id" => svc_id } },
          after: { "name" => "orders-route", "paths" => [ "/changed" ], "service" => { "id" => svc_id } })
        expect(doc["services"][0]["routes"]).to eq([ { "name" => "orders-route", "paths" => [ "/changed" ] } ])

        render_change(entity_type: "route", operation: "delete", before: { "name" => "orders-route", "service" => { "id" => svc_id } })
        expect(doc["services"][0]["routes"]).to eq([])
      end
    end

    describe "upstreams and targets" do
      it "renders an upstream at the top level" do
        render_change(entity_type: "upstream", operation: "create", after: { "name" => "orders-up", "slots" => 10_000, "host_header" => nil })

        expect(doc["upstreams"]).to eq([ { "name" => "orders-up", "slots" => 10_000 } ])
      end

      it "nests a target under its upstream only, dropping the upstream reference" do
        doc["upstreams"] = [ { "name" => "orders-up" } ]

        render_change(entity_type: "target", operation: "create", parent_kong_id: up_id,
          after: { "target" => "10.0.0.1:80", "weight" => 100, "upstream" => { "id" => up_id }, "tags" => nil })

        expect(doc["upstreams"][0]["targets"]).to eq([ { "target" => "10.0.0.1:80", "weight" => 100 } ])
        expect(doc).not_to have_key("targets")
      end

      it "deletes only the named target" do
        doc["upstreams"] = [ { "name" => "orders-up", "targets" => [ { "target" => "10.0.0.1:80" }, { "target" => "10.0.0.2:80" } ] } ]

        render_change(entity_type: "target", operation: "delete", parent_kong_id: up_id, before: { "target" => "10.0.0.1:80" })

        expect(doc["upstreams"][0]["targets"]).to eq([ { "target" => "10.0.0.2:80" } ])
      end

      it "refuses a target whose upstream is not in the YAML" do
        expect {
          render_change(entity_type: "target", operation: "create", parent_kong_id: up_id, after: { "target" => "10.0.0.1:80" })
        }.to raise_error(Kong::DeckRenderer::Unrenderable, /the upstream orders-up isn't in this YAML/)
      end
    end

    describe "consumers" do
      it "renders a consumer by username, leaving out custom_id when it is null" do
        render_change(entity_type: "consumer", operation: "create", after: { "username" => "reporting-bot", "custom_id" => nil, "tags" => nil })

        expect(doc["consumers"]).to eq([ { "username" => "reporting-bot" } ])
      end

      it "updates and deletes by username" do
        doc["consumers"] = [ { "username" => "reporting-bot", "tags" => [ "a" ] } ]

        render_change(entity_type: "consumer", operation: "update", before: { "username" => "reporting-bot" },
          after: { "username" => "reporting-bot", "tags" => [ "b" ] })
        expect(doc["consumers"]).to eq([ { "username" => "reporting-bot", "tags" => [ "b" ] } ])

        render_change(entity_type: "consumer", operation: "delete", before: { "username" => "reporting-bot" })
        expect(doc["consumers"]).to eq([])
      end
    end

    describe "plugins" do
      before do
        doc["services"] = [ { "name" => "orders", "routes" => [ { "name" => "orders-route" } ] } ]
        doc["consumers"] = [ { "username" => "reporting-bot" } ]
      end

      it "puts a global plugin in the top-level list" do
        render_change(entity_type: "plugin", operation: "create",
          after: { "name" => "correlation-id", "service" => nil, "route" => nil, "consumer" => nil, "config" => {} })

        expect(doc["plugins"]).to eq([ { "name" => "correlation-id", "config" => {} } ])
      end

      it "nests a service-scoped plugin under its service, without the scope reference" do
        render_change(entity_type: "plugin", operation: "create",
          after: { "name" => "request-size-limiting", "service" => { "id" => svc_id }, "config" => { "allowed_payload_size" => 8 } })

        expect(doc["services"][0]["plugins"]).to eq([ { "name" => "request-size-limiting", "config" => { "allowed_payload_size" => 8 } } ])
      end

      it "nests a route-scoped plugin under that route, inside its service" do
        render_change(entity_type: "plugin", operation: "create",
          after: { "name" => "rate-limiting", "route" => { "id" => route_id }, "config" => { "minute" => 60 } })

        expect(doc["services"][0]["routes"][0]["plugins"]).to eq([ { "name" => "rate-limiting", "config" => { "minute" => 60 } } ])
      end

      it "nests a consumer-scoped plugin under its consumer" do
        render_change(entity_type: "plugin", operation: "create", after: { "name" => "cors", "consumer" => { "id" => con_id }, "config" => {} })

        expect(doc["consumers"][0]["plugins"]).to eq([ { "name" => "cors", "config" => {} } ])
      end

      it "refuses a plugin scoped to more than one entity, which decK YAML cannot express" do
        expect {
          render_change(entity_type: "plugin", operation: "create",
            after: { "name" => "x", "service" => { "id" => svc_id }, "consumer" => { "id" => con_id } })
        }.to raise_error(Kong::DeckRenderer::Unrenderable, /scoped to service and consumer can't be written/)
      end

      it "finds a plugin to update or delete by name inside its scope" do
        doc["services"][0]["plugins"] = [ { "name" => "request-size-limiting", "config" => { "allowed_payload_size" => 8 } } ]
        scope = { "service" => { "id" => svc_id } }

        render_change(entity_type: "plugin", operation: "update", before: { "name" => "request-size-limiting" }.merge(scope),
          after: { "name" => "request-size-limiting", "config" => { "allowed_payload_size" => 16 } }.merge(scope))
        expect(doc["services"][0]["plugins"][0]["config"]).to eq({ "allowed_payload_size" => 16 })

        render_change(entity_type: "plugin", operation: "delete", before: { "name" => "request-size-limiting" }.merge(scope))
        expect(doc["services"][0]["plugins"]).to eq([])
      end
    end

    describe "certificates, SNIs and CA certificates" do
      let(:vault_key) { "{vault://env/cert-pay-key}" }
      let(:create_after) do
        { "cert" => pem, "cert_alt" => nil, "key" => vault_key, "key_alt" => nil, "snis" => [ "a.example.internal" ], "tags" => [ "team-a" ] }
      end

      it "mints a UUID for a new certificate, writes it as the YAML id, and records it on the plan" do
        cert_plan = plan(entity_type: "certificate", operation: "create", after: create_after)

        described_class.apply_change(doc, cert_plan, resolver: resolver)

        minted = cert_plan.target_kong_id
        expect(minted).to match(/\A\h{8}-\h{4}-\h{4}-\h{4}-\h{12}\z/)
        expect(doc["certificates"]).to eq([ { "id" => minted, "cert" => pem, "key" => vault_key, "tags" => [ "team-a" ],
                                              "snis" => [ { "name" => "a.example.internal" } ] } ])
      end

      it "passes a decK env placeholder through untouched, for the serializer to single-quote" do
        placeholder = %q(${{ env "DECK_CERT_PAY_KEY" }})

        render_change(entity_type: "certificate", operation: "create", after: create_after.merge("key" => placeholder))

        expect(doc["certificates"][0]["key"]).to eq(placeholder)
        expect(Kong::DeckDocument.serialize(doc)).to include(%q(key: '${{ env "DECK_CERT_PAY_KEY" }}'))
      end

      it "matches a certificate by id on update, keeps the id and the SNI entries it already has" do
        doc["certificates"] = [ { "id" => cert_id, "cert" => pem, "key" => vault_key, "tags" => [ "x" ],
                                  "snis" => [ { "name" => "a.example.internal", "tags" => [ "t" ] } ] } ]

        render_change(entity_type: "certificate", operation: "update", target_kong_id: cert_id,
          before: { "id" => cert_id, "tags" => [ "x" ] },
          after: { "id" => cert_id, "tags" => %w[x y], "snis" => [ "a.example.internal", "b.example.internal" ] })

        expect(doc["certificates"]).to eq([ { "id" => cert_id, "cert" => pem, "key" => vault_key, "tags" => %w[x y],
                                              "snis" => [ { "name" => "a.example.internal", "tags" => [ "t" ] }, { "name" => "b.example.internal" } ] } ])
      end

      it "refuses a certificate update when no YAML entry carries its id" do
        doc["certificates"] = [ { "id" => "ffffffff-0000-0000-0000-000000000000", "cert" => pem } ]

        expect {
          render_change(entity_type: "certificate", operation: "update", target_kong_id: cert_id, before: { "id" => cert_id }, after: { "tags" => [ "x" ] })
        }.to raise_error(Kong::DeckRenderer::Unrenderable, /no certificate with id #{cert_id} in this YAML/)
      end

      it "deletes a certificate, taking its nested SNIs with it" do
        doc["certificates"] = [ { "id" => cert_id, "cert" => pem, "snis" => [ { "name" => "a.example.internal" } ] } ]

        render_change(entity_type: "certificate", operation: "delete", target_kong_id: cert_id, before: { "id" => cert_id })

        expect(doc["certificates"]).to eq([])
      end

      it "nests an SNI under its certificate, matched by the certificate's id" do
        doc["certificates"] = [ { "id" => cert_id, "cert" => pem } ]

        render_change(entity_type: "sni", operation: "create", parent_kong_id: cert_id,
          after: { "name" => "b.example.internal", "certificate" => { "id" => cert_id }, "tags" => nil })

        expect(doc["certificates"][0]["snis"]).to eq([ { "name" => "b.example.internal" } ])
      end

      it "deletes an SNI, finding its certificate from the SNI's own certificate reference" do
        doc["certificates"] = [ { "id" => cert_id, "cert" => pem, "snis" => [ { "name" => "a.example.internal" }, { "name" => "b.example.internal" } ] } ]

        render_change(entity_type: "sni", operation: "delete", before: { "name" => "a.example.internal", "certificate" => { "id" => cert_id } })

        expect(doc["certificates"][0]["snis"]).to eq([ { "name" => "b.example.internal" } ])
      end

      it "refuses an SNI whose certificate is not in the YAML" do
        expect {
          render_change(entity_type: "sni", operation: "create", parent_kong_id: cert_id, after: { "name" => "b.example.internal" })
        }.to raise_error(Kong::DeckRenderer::Unrenderable, /the certificate #{cert_id} isn't in this YAML/)
      end

      it "renders a CA certificate without an id (decK does not require one)" do
        render_change(entity_type: "ca_certificate", operation: "create", after: { "cert" => pem, "cert_digest" => "abc", "tags" => [ "team-a" ] })

        expect(doc["ca_certificates"]).to eq([ { "cert" => pem, "cert_digest" => "abc", "tags" => [ "team-a" ] } ])
      end

      it "refuses a CA certificate that is already in the YAML, and finds one by its cert text to update or delete" do
        doc["ca_certificates"] = [ { "cert" => pem, "tags" => [ "a" ] } ]

        expect { render_change(entity_type: "ca_certificate", operation: "create", after: { "cert" => pem }) }
          .to raise_error(Kong::DeckRenderer::Unrenderable, /already in this YAML/)

        render_change(entity_type: "ca_certificate", operation: "update", before: { "cert" => pem }, after: { "cert" => pem, "tags" => [ "b" ] })
        expect(doc["ca_certificates"]).to eq([ { "cert" => pem, "tags" => [ "b" ] } ])

        render_change(entity_type: "ca_certificate", operation: "delete", before: { "cert" => pem })
        expect(doc["ca_certificates"]).to eq([])
      end
    end

    describe "credentials" do
      it "are deliberately never rendered (docs/DESIGN.md 1.7), and say so" do
        %w[keyauth_credential basicauth_credential].each do |type|
          expect { render_change(entity_type: type, operation: "create", after: { "key" => "x" }) }
            .to raise_error(NotImplementedError, /#{type} is deliberately never rendered/)
        end
      end

      it "can be checked without a document, so the applier can refuse before touching git" do
        expect { described_class.assert_supported!("keyauth_credential") }.to raise_error(NotImplementedError)
        expect(described_class.assert_supported!("route")).to be_nil
      end
    end

    it "leaves no null, timestamp or parent reference anywhere in what it renders" do
      doc["services"] = [ { "name" => "orders" } ]
      render_change(entity_type: "route", operation: "create", after: {
        "name" => "r", "paths" => [ "/o" ], "hosts" => nil, "headers" => nil, "created_at" => 1, "updated_at" => 2,
        "service" => { "id" => svc_id }, "regex_priority" => 0
      })

      expect(Kong::DeckDocument.serialize(doc)).not_to match(/: null|created_at|updated_at|service:\s*\n\s+id:/)
    end
  end
```

- [ ] **Step 3: Run and confirm the right failure**

Run: `bundle exec rspec -r "$K" spec/services/kong/deck_read_model_resolver_spec.rb spec/services/kong/deck_renderer_spec.rb`

Expected: the resolver spec FAILS (`uninitialized constant Kong::DeckReadModelResolver`); the renderer `.apply_change` examples FAIL (`NameError` for the resolver/`Unrenderable`, or `ArgumentError` from the old implementation). The old `.parse`/`.serialize` examples still PASS.

- [ ] **Step 4: Implement the resolver**

Create `app/services/kong/deck_read_model_resolver.rb`:

```ruby
module Kong
  # What the read-model calls an entity, for the renderer: a decK YAML entry is
  # nested under its parent by the parent's *name* (service, upstream,
  # consumer), and a plugin scoped to a route needs the route's service too.
  # Kong's own uuids are not in the file, so the read-model is the bridge.
  # Everything is scoped to one connection and skips soft-deleted rows; an
  # unknown or malformed id answers nil, never raises.
  class DeckReadModelResolver
    def initialize(connection)
      @connection = connection
    end

    def name_of(kong_id)
      entity(kong_id)&.name
    end

    def parent_of(kong_id)
      entity(kong_id)&.parent_kong_id
    end

    private

    def entity(kong_id)
      return nil if @connection.nil? || kong_id.blank?

      KongEntity.active.find_by(kong_connection: @connection, kong_id: kong_id)
    end
  end
end
```

- [ ] **Step 5: Implement the renderer**

In `app/services/kong/deck_renderer.rb`: **delete the old `self.apply_change` method and the old `self.renderable` method (with its `private_class_method :renderable` line)**. Leave `FORMAT_VERSION`, `self.parse`, `self.serialize`, `self.service_lines`, `self.value_lines` and `self.scalar` untouched (Task 6 removes them). Add `class Unrenderable` directly under `class DeckRenderer`, and insert the following where `apply_change` was:

```ruby
    # A change that cannot be written into decK YAML faithfully. A guardrail
    # Violation, so it surfaces like any other refusal (API 403 / web redirect)
    # rather than a 500 -- and always an error, never a silent omission.
    class Unrenderable < Kong::ChangeGuardrails::Violation; end

    MANAGED = Kong::EntityTypes::KONG_MANAGED_FIELDS

    # A credential is never rendered: decK would sync password hashes back into
    # Kong and break real logins (docs/DESIGN.md section 1.7). Checked on its own
    # so the applier can refuse before it touches git.
    def self.assert_supported!(entity_type)
      return if Kong::EntityTypes.fetch(entity_type).deck_supported?

      raise NotImplementedError, "#{entity_type} is deliberately never rendered into decK YAML " \
        "(credentials are hashed at rest, so a re-sync would corrupt them -- docs/DESIGN.md section 1.7)"
    end

    # Mutates `doc` in place per `change_plan.operation`, then returns it. Where
    # the entity lives, and what matches it, come from the registry
    # (Kong::EntityTypes decK facts); `resolver` names parents. A certificate
    # create mints its own uuid (decK requires an id on certificates, and Kong
    # accepts a client-supplied one), stored on the plan's target_kong_id so
    # the read-model can match the entity once CI syncs it.
    def self.apply_change(doc, change_plan, resolver: Kong::DeckReadModelResolver.new(change_plan.kong_connection))
      assert_supported!(change_plan.entity_type)
      definition = Kong::EntityTypes.fetch(change_plan.entity_type)
      list = container(doc, change_plan, resolver)

      case change_plan.operation
      when "create" then create(list, change_plan, definition)
      when "update" then update(list, change_plan, definition)
      when "delete" then delete(list, change_plan, definition)
      else raise Unrenderable, "unknown operation #{change_plan.operation}"
      end

      doc
    end

    def self.create(list, plan, definition)
      entry = renderable(plan.after, definition)
      if plan.entity_type == "certificate"
        entry["id"] = (plan.target_kong_id ||= SecureRandom.uuid)
      else
        raise Unrenderable, "a #{plan.entity_type} needs a #{definition.deck_key} to be written into decK YAML" if identity_missing?(plan, definition)
        raise Unrenderable, "#{plan.entity_type} #{identity_label(plan, definition)} is already in this YAML" if find_index(list, plan, definition)
      end

      list << entry
    end
    private_class_method :create

    def self.update(list, plan, definition)
      index = locate!(list, plan, definition)
      existing = list[index]
      incoming = plan.after.except(*MANAGED)
      incoming["snis"] = keep_sni_entries(existing["snis"], incoming["snis"]) if plan.entity_type == "certificate" && incoming["snis"].is_a?(Array)

      list[index] = renderable(existing.merge(incoming), definition, keep_id: true)
    end
    private_class_method :update

    def self.delete(list, plan, definition)
      list.delete_at(locate!(list, plan, definition))
    end
    private_class_method :delete

    # Kong returns a certificate's `snis` as names; in YAML each is an entry that
    # may carry its own fields (tags). Keep the entries already there.
    def self.keep_sni_entries(existing, names)
      by_name = Array(existing).select { |entry| entry.is_a?(Hash) }.index_by { |entry| entry["name"] }
      names.map { |name| name.is_a?(Hash) ? name : (by_name[name] || { "name" => name }) }
    end
    private_class_method :keep_sni_entries

    def self.locate!(list, plan, definition)
      raise Unrenderable, "can't tell which #{plan.entity_type} this is (no #{definition.deck_key})" if identity_missing?(plan, definition)

      find_index(list, plan, definition) ||
        raise(Unrenderable, "no #{plan.entity_type} with #{definition.deck_key} #{identity_label(plan, definition)} in this YAML " \
          "-- it isn't managed through the config repo")
    end
    private_class_method :locate!

    # A certificate is matched by its Kong id. A CA certificate by id when the
    # entry has one, else by its cert text (decK does not require an id there).
    # Everything else by its identity field (`name`, `target`, `username`).
    def self.find_index(list, plan, definition)
      key = definition.deck_key
      if plan.entity_type == "ca_certificate"
        cert = (plan.before["cert"] || plan.after["cert"]).to_s.strip
        list.index do |entry|
          entry.is_a?(Hash) && ((plan.target_kong_id.present? && entry["id"] == plan.target_kong_id) || (cert.present? && entry["cert"].to_s.strip == cert))
        end
      else
        value = identity_value(plan, definition)
        list.index { |entry| entry.is_a?(Hash) && entry[key] == value }
      end
    end
    private_class_method :find_index

    def self.identity_value(plan, definition)
      key = definition.deck_key
      key == "id" ? plan.target_kong_id : (plan.before[key].presence || plan.after[key].presence)
    end
    private_class_method :identity_value

    def self.identity_missing?(plan, definition)
      return false if plan.entity_type == "ca_certificate"

      identity_value(plan, definition).blank?
    end
    private_class_method :identity_missing?

    def self.identity_label(plan, definition)
      plan.entity_type == "ca_certificate" ? "with this cert" : identity_value(plan, definition)
    end
    private_class_method :identity_label

    # The list a change lands in. A child lives inside its parent (decK accepts
    # a target no other way), so the parent has to be in the file already.
    def self.container(doc, plan, resolver)
      case plan.entity_type
      when "route" then child(doc, "services", "name", resolver.name_of(parent_id(plan, "service")), "service", "routes")
      when "target" then child(doc, "upstreams", "name", resolver.name_of(parent_id(plan, "upstream")), "upstream", "targets")
      when "sni" then child(doc, "certificates", "id", parent_id(plan, "certificate"), "certificate", "snis")
      when "plugin" then plugin_container(doc, plan, resolver)
      else top(doc, Kong::EntityTypes.fetch(plan.entity_type).deck_collection)
      end
    end
    private_class_method :container

    def self.plugin_container(doc, plan, resolver)
      scopes = %w[service route consumer].select { |scope| scope_id(plan, scope) }
      raise Unrenderable, "a plugin scoped to #{scopes.join(' and ')} can't be written into decK YAML" if scopes.size > 1
      return top(doc, "plugins") if scopes.empty?

      case scopes.first
      when "service" then child(doc, "services", "name", resolver.name_of(scope_id(plan, "service")), "service", "plugins")
      when "consumer" then child(doc, "consumers", "username", resolver.name_of(scope_id(plan, "consumer")), "consumer", "plugins")
      else
        route_id = scope_id(plan, "route")
        service = child_entry(doc, "services", "name", resolver.name_of(resolver.parent_of(route_id)), "service")
        route = child_entry(service, "routes", "name", resolver.name_of(route_id), "route")
        route["plugins"] = [] unless route["plugins"].is_a?(Array)
        route["plugins"]
      end
    end
    private_class_method :plugin_container

    def self.top(doc, collection)
      doc[collection] = [] unless doc[collection].is_a?(Array)
      doc[collection]
    end
    private_class_method :top

    def self.child(holder, collection, key, value, parent_type, list_name)
      parent = child_entry(holder, collection, key, value, parent_type)
      parent[list_name] = [] unless parent[list_name].is_a?(Array)
      parent[list_name]
    end
    private_class_method :child

    def self.child_entry(holder, collection, key, value, parent_type)
      raise Unrenderable, "can't tell which #{parent_type} this belongs to" if value.blank?

      Array(holder[collection]).find { |entry| entry.is_a?(Hash) && entry[key] == value } ||
        raise(Unrenderable, "the #{parent_type} #{value} isn't in this YAML, so nothing can be nested under it")
    end
    private_class_method :child_entry

    # The parent's Kong id: what the planner stored (a target's upstream), else
    # the reference the entity's own JSON carries (a route's `service`).
    def self.parent_id(plan, reference)
      plan.parent_kong_id.presence || scope_id(plan, reference)
    end
    private_class_method :parent_id

    def self.scope_id(plan, reference)
      value = plan.after[reference] || plan.before[reference]
      value.is_a?(Hash) ? value["id"] : nil
    end
    private_class_method :scope_id

    # What a document may hold once it is a decK entry: no Kong bookkeeping, no
    # reference to the parent it is nested inside, and no nulls -- decK rejects
    # `custom_id: null` (measured, M5c) and Kong returns nulls constantly.
    def self.renderable(attrs, definition, keep_id: false)
      managed = keep_id ? MANAGED - %w[id] : MANAGED
      cleaned = compact(attrs.except(*managed, *definition.deck_refs))
      cleaned["snis"] = cleaned["snis"].map { |sni| sni.is_a?(Hash) ? sni : { "name" => sni } } if cleaned["snis"].is_a?(Array)
      cleaned
    end
    private_class_method :renderable

    def self.compact(node)
      case node
      when Hash then node.each_with_object({}) { |(key, value), result| result[key] = compact(value) unless value.nil? }
      when Array then node.map { |value| compact(value) }
      else node
      end
    end
    private_class_method :compact
```

- [ ] **Step 6: Run to green, RuboCop, whole suite**

Run: `bundle exec rspec -r "$K" spec/services/kong/deck_read_model_resolver_spec.rb spec/services/kong/deck_renderer_spec.rb` — all PASS (the old `.parse`/`.serialize` examples included).
Run: `bundle exec rubocop app/services/kong/deck_read_model_resolver.rb app/services/kong/deck_renderer.rb spec/services/kong/deck_read_model_resolver_spec.rb spec/services/kong/deck_renderer_spec.rb` — no offenses.
Run: `bundle exec rspec -r "$K"` — 0 failures. The applier's existing service-only PR specs still pass: the applier still guards on `entity_type == "service"` and still calls `DeckRenderer.parse/serialize`, which still exist. (If an existing applier PR spec fails, the old `apply_change(doc, plan)` contract changed — that is a real finding.)

- [ ] **Step 7: Prove placement against the real decK binary and real Kong JSON**

Write `<scratchpad>/verify_renderer.rb` (Write tool) and run it as in Task 4 Step 5 (`bin/rails runner`, `RAILS_ENV=test`, `DECK_BINS=…`). It renders **all nine types** through the real classes, from JSON shaped like Kong 3.7's (nulls, `created_at`, `service: {id}` references, timestamps, a certificate's `snis` as names) and asks decK to validate the result:

```ruby
require "open3"
require "tmpdir"
require "securerandom"

bins = ENV.fetch("DECK_BINS").split(",")
svc, route_id, up, con, cert = SecureRandom.uuid, SecureRandom.uuid, SecureRandom.uuid, SecureRandom.uuid, nil
names = { svc => "orders", route_id => "orders-route", up => "orders-up", con => "reporting-bot" }
parents = { route_id => svc }
resolver = Object.new
resolver.define_singleton_method(:name_of) { |id| names[id] }
resolver.define_singleton_method(:parent_of) { |id| parents[id] }

require Rails.root.join("spec/support/pem_fixtures")
pem = PemFixtures.self_signed(cn: "e2e.example.internal", days: 30)[:cert_pem]

doc = Kong::DeckDocument.parse(nil, select_tags: [ "team-a" ])
r = lambda do |type, op, after: {}, before: {}, target: nil, parent: nil|
  plan = ChangePlan.new(entity_type: type, operation: op, after: after, before: before, target_kong_id: target, parent_kong_id: parent)
  Kong::DeckRenderer.apply_change(doc, plan, resolver: resolver)
  plan
end

r.call("service", "create", after: { "id" => svc, "name" => "orders", "host" => "orders.internal", "port" => 80, "protocol" => "http", "retries" => 5,
  "tls_verify" => nil, "ca_certificates" => nil, "client_certificate" => nil, "created_at" => 1, "updated_at" => 2, "tags" => [ "team-a" ] })
r.call("route", "create", after: { "id" => route_id, "name" => "orders-route", "paths" => [ "/o" ], "hosts" => nil, "methods" => nil,
  "headers" => nil, "snis" => nil, "sources" => nil, "destinations" => nil, "service" => { "id" => svc }, "strip_path" => true, "tags" => [ "team-a" ] })
r.call("consumer", "create", after: { "id" => con, "username" => "reporting-bot", "custom_id" => nil, "tags" => [ "team-a" ] })
r.call("plugin", "create", after: { "name" => "correlation-id", "service" => nil, "route" => nil, "consumer" => nil, "config" => {}, "tags" => [ "team-a" ] })
r.call("plugin", "create", after: { "name" => "request-size-limiting", "service" => { "id" => svc }, "config" => { "allowed_payload_size" => 8 } })
r.call("plugin", "create", after: { "name" => "rate-limiting", "route" => { "id" => route_id }, "config" => { "minute" => 60, "policy" => "local" } })
r.call("plugin", "create", after: { "name" => "cors", "consumer" => { "id" => con }, "config" => {} })
r.call("upstream", "create", after: { "id" => up, "name" => "orders-up", "algorithm" => "round-robin", "hash_on" => "none", "host_header" => nil,
  "client_certificate" => nil, "slots" => 10_000, "tags" => [ "team-a" ] })
r.call("target", "create", parent: up, after: { "target" => "10.0.0.1:80", "weight" => 100, "upstream" => { "id" => up }, "tags" => nil })
cert_plan = r.call("certificate", "create", after: { "cert" => pem, "cert_alt" => nil, "key" => "{vault://env/cert-e2e-key}", "key_alt" => nil,
  "snis" => [ "e2e.example.internal" ], "tags" => [ "team-a" ] })
r.call("sni", "create", parent: cert_plan.target_kong_id, after: { "name" => "b.example.internal", "certificate" => { "id" => cert_plan.target_kong_id }, "tags" => nil })
r.call("ca_certificate", "create", after: { "cert" => pem, "cert_digest" => "abc", "tags" => [ "team-a" ] })

text = Kong::DeckDocument.serialize(doc)
Dir.mktmpdir do |dir|
  path = File.join(dir, "kong.yaml")
  File.write(path, text)
  bins.each do |bin|
    _o, e, st = Open3.capture3({}, bin, "file", "validate", path)
    puts "#{st.success? ? 'PASS' : 'FAIL'} decK #{File.basename(File.dirname(bin))} accepts all nine types#{st.success? ? '' : " -- #{e.scan(/err=([^\n]*)/).flatten.first(2).join(' | ')}"}"
  end
end
puts(Kong::DeckDocument.serialize(Kong::DeckDocument.parse(text, select_tags: [ "team-a" ])) == text ? "PASS fixed point" : "FAIL not a fixed point")
puts(text.match?(/: null|created_at|updated_at/) ? "FAIL null/timestamp leaked" : "PASS nothing null, no timestamps")
```

Run it; expected: `PASS decK deck1511 …`, `PASS decK deck1661 …`, `PASS fixed point`, `PASS nothing null, no timestamps`. A FAIL is a real finding: report it, do not weaken the script.

- [ ] **Step 8: Commit**

Normalise the two new files and the two edited files to CRLF (check with a Ruby count; the Edit tool can change endings), then:

```bash
git add app/services/kong/deck_read_model_resolver.rb spec/services/kong/deck_read_model_resolver_spec.rb app/services/kong/deck_renderer.rb spec/services/kong/deck_renderer_spec.rb
git commit -m "feat(m5c): DeckRenderer places all nine managed types, nested, from the registry" -m "Children nest inside their parent (a target is accepted no other way), parents are named through the read-model, a certificate create mints the uuid decK requires, and nulls and parent references are stripped because decK rejects them. Anything that cannot be written faithfully raises Unrenderable, a Violation subclass. Credentials raise a deliberate NotImplementedError. Verified against decK 1.51.1 and 1.66.1 with Kong-shaped JSON." -m "Co-Authored-By: Claude Sonnet 5 <noreply@anthropic.com>"
```

---

### Task 6: The applier renders every type, and refuses input it cannot reproduce

**Files:**
- Modify: `app/services/kong/change_applier.rb`, `app/services/kong/deck_renderer.rb`, `lib/tasks/kong.rake`
- Modify: `spec/services/kong/change_applier_spec.rb`, `spec/services/kong/deck_renderer_spec.rb`, `spec/requests/change_plans_spec.rb`

**Interfaces:**
- Consumes: `Kong::DeckDocument.parse/serialize/verify_input!` (Task 4), `Kong::DeckRenderer.apply_change/assert_supported!` (Task 5), `Kong::DeckCli` (Task 1).
- Produces: `ChangeApplier#execute_pr!` for **any** managed type. New refusals, all raised **before the branch is touched** (the repo is left clean, the plan stays `pending`): `Kong::DeckDocument::Unparseable` (input does not round-trip), `Kong::DeckRenderer::Unrenderable`, and the deliberate `NotImplementedError` for a credential, now raised before git is even pulled. A certificate create's minted uuid is persisted on the plan (`target_kong_id`) and appears in the audit event. `Kong::DeckRenderer.parse/serialize` are **removed**; every caller uses `Kong::DeckDocument`.

The acknowledgement gate needs no change: `require_env_acknowledgement!` already runs before the PR/direct branch (M5b Task 7), so a vault-referenced key still needs it in PR mode. A decK placeholder needs none (it is CI's concern — spec §6, corrected).

- [ ] **Step 1: Write the failing applier specs**

In `spec/services/kong/change_applier_spec.rb`, first make sure the file requires the PEM fixtures near the top (add `require Rails.root.join("spec/support/pem_fixtures")` under `require "rails_helper"` if it is not already there).

Change the seed line in the PR-mode `before` block (currently `Kong::DeckRenderer.serialize(Kong::DeckRenderer.parse(nil, select_tags: [ "managed-by-kongctl" ]))`) to:

```ruby
      File.write(scratch.join("kong.yaml"), Kong::DeckDocument.serialize(Kong::DeckDocument.parse(nil, select_tags: [ "managed-by-kongctl" ])))
```

Delete the two examples that assert PR mode is service-only — `"raises a clear NotImplementedError for a PR-mode plan on any entity_type but service"` and `"leaves an upstream or target PR-mode plan pending, untouched, until M5c renders them into decK YAML"` — and, in the same place inside the PR-mode `describe`, add these helpers and examples. (`sh!`, `bare_repo`, `pr_connection`, `pr_client` already exist in this block; reuse them.)

```ruby
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
```

- [ ] **Step 2: Run and confirm the right failures**

Run: `bundle exec rspec -r "$K" spec/services/kong/change_applier_spec.rb`

Expected: the new examples FAIL — the applier still says `PR-mode apply only supports service changes today` (`NotImplementedError`) for route/upstream/certificate, and never calls `verify_input!`. The credential example fails only on its message (`/deliberately never rendered/`). Existing examples still PASS.

- [ ] **Step 3: Implement the applier**

In `app/services/kong/change_applier.rb`, replace `execute_pr!` and `verify_round_trip!` (keep `read_yaml`, `commit_message`, `parse`, `record_audit_event!`):

```ruby
    # docs/DESIGN.md section 6, "เส้นทางของ PR mode" steps 2-8: pull the
    # config repo, refuse a file the tool could not reproduce, mutate + serialize
    # its YAML (rules ก-ค), validate + diff against Kong with the read-only
    # credential already in hand, commit to a branch, and push. No PR-host API
    # call -- see Kong::GitClient. Everything that can refuse does so before the
    # branch is touched: the repo is left clean and the plan stays pending.
    def execute_pr!
      Kong::DeckRenderer.assert_supported!(@change_plan.entity_type)

      git = Kong::GitClient.new(connection: @connection).pull!

      text = read_yaml(git)
      Kong::DeckDocument.verify_input!(text)
      doc = Kong::DeckDocument.parse(text, select_tags: @connection.select_tags)
      Kong::DeckRenderer.apply_change(doc, @change_plan)
      rendered = Kong::DeckDocument.serialize(doc)
      verify_round_trip!(rendered)

      branch = "#{BRANCH_PREFIX}/#{@change_plan.id}"
      git.checkout_branch!(branch)
      git.write_file(@connection.git_path, rendered)

      file_path = git.working_dir.join(@connection.git_path)
      Kong::DeckCli.validate(file_path)
      deck_diff = Kong::DeckCli.diff(file_path, connection: @connection, secret: @secret)

      commit_sha = git.commit!(commit_message, author_name: @actor_username)
      git.push!(branch)

      # Also persists a certificate create's minted id (target_kong_id), which
      # Kong::DeckRenderer assigned on this same object.
      @change_plan.update!(commit_sha: commit_sha, deck_diff: deck_diff, pr_state: "branch_pushed")
    end

    def read_yaml(git)
      path = git.working_dir.join(@connection.git_path)
      File.exist?(path) ? File.read(path) : nil
    end

    def verify_round_trip!(rendered)
      Kong::DeckDocument.verify_input!(rendered)
    rescue Kong::DeckDocument::Unparseable
      raise Kong::ChangeGuardrails::Violation,
        "rendered YAML did not round-trip byte-for-byte -- refusing to push a diff that would be noisy to review"
    end
```

- [ ] **Step 4: Remove the old `DeckRenderer.parse`/`serialize` and repoint every caller**

In `app/services/kong/deck_renderer.rb`, delete `FORMAT_VERSION`, `self.parse`, `self.serialize`, `self.service_lines`, `self.value_lines`, `self.scalar` and their `private_class_method` lines. Replace the class comment at the top with:

```ruby
module Kong
  # Places a change_plan's entity into a decK config document -- docs/DESIGN.md
  # section 6 ("เส้นทางของ PR mode", step 3). The file format itself (parse,
  # serialize, the input guard) is Kong::DeckDocument; this class only decides
  # WHERE in it an entity lives and what it may contain. Rule ง (never render an
  # admin-path entity or a consumer credential) is enforced one level up for the
  # first, and here for credentials (see assert_supported!).
  #
  # Where each type goes, and what identifies it, are registry facts
  # (Kong::EntityTypes decK fields); the rules were measured against decK
  # 1.51.1 and 1.66.1 -- docs/superpowers/specs/2026-09-21-m5c-deck-rendering-
  # design.md sections 1 and 4.
  class DeckRenderer
```

Leave no blank line directly after `class DeckRenderer` (RuboCop `Layout/EmptyLinesAroundClassBody`).

In `spec/services/kong/deck_renderer_spec.rb`, delete the `describe ".parse"` and `describe ".serialize"` blocks (their coverage now lives in `deck_document_spec.rb`).

Change the three remaining callers:
- `lib/tasks/kong.rake`, the `skeleton = …` line: `skeleton = Kong::DeckDocument.serialize(Kong::DeckDocument.parse(nil, select_tags: [ "managed-by-kongctl" ]))`
- `spec/requests/change_plans_spec.rb`, the `File.write(scratch.join("kong.yaml"), …)` line (≈ line 240): same replacement with `Kong::DeckDocument`.
- Nothing else references `DeckRenderer.parse`/`serialize` — confirm with: `grep -rn "DeckRenderer\.\(parse\|serialize\)" app spec lib bin` (expect no output).

- [ ] **Step 5: Run to green, RuboCop, whole suite**

Run: `bundle exec rspec -r "$K" spec/services/kong/change_applier_spec.rb spec/services/kong/deck_renderer_spec.rb spec/requests/change_plans_spec.rb` — all PASS.
Run: `bundle exec rubocop app/services/kong/change_applier.rb app/services/kong/deck_renderer.rb lib/tasks/kong.rake spec/services/kong/change_applier_spec.rb spec/services/kong/deck_renderer_spec.rb spec/requests/change_plans_spec.rb` — no offenses.
Run: `bundle exec rspec -r "$K"` — 0 failures.

- [ ] **Step 6: Commit**

Confirm line endings (Ruby count) on every touched file, then:

```bash
git add app/services/kong/change_applier.rb app/services/kong/deck_renderer.rb lib/tasks/kong.rake spec/services/kong/change_applier_spec.rb spec/services/kong/deck_renderer_spec.rb spec/requests/change_plans_spec.rb
git commit -m "feat(m5c): PR-mode apply renders every managed type and refuses input it cannot reproduce" -m "Drops the service-only guard. The file is now checked on input (a comment, an anchor or hand formatting would be silently rewritten, and sync deletes whatever is absent), an unrenderable change or a credential is refused before git is touched, and a certificate create's minted id is persisted and audited. DeckRenderer.parse/serialize are gone; DeckDocument replaces them everywhere." -m "Co-Authored-By: Claude Sonnet 5 <noreply@anthropic.com>"
```

---

### Task 7: decK and git failures reach the operator instead of a 500

**Files:**
- Modify: `app/controllers/change_plans_controller.rb`, `app/controllers/api/v1/change_plans_controller.rb`
- Modify: `spec/requests/change_plans_spec.rb`, `spec/requests/api/v1/change_plans_spec.rb`

**Interfaces:**
- Consumes: `Kong::DeckCli::Error`, `Kong::GitClient::Error` (both already raised by the applier, which marks the plan `failed` for them and re-raises), `Kong::CertificateKeyPolicy.scrub`, the API controller's existing `safe_message`.
- Produces: web `apply` redirects back to the review page with the message as an alert; API `apply` answers **422** for `DeckCli::Error` and **502** for `GitClient::Error`, body `{error: <scrubbed message>}`.

Why: neither controller rescued these, so a decK rejection — the very message an operator needs ("routes.0: name is required") — was an unhandled 500. Before M5c almost nothing could reach `DeckCli`; now every type can.

- [ ] **Step 1: Write the failing specs**

In `spec/requests/change_plans_spec.rb`, add beside the existing top-level apply examples (they use `sign_in` and the file's `connection`; the applier is stubbed at its boundary, so the plan's contents do not matter):

```ruby
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
```

In `spec/requests/api/v1/change_plans_spec.rb`, add inside `describe "POST /api/v1/change_plans/:id/apply (kong_apply)"` (each example there builds its own `connection`, `token` and `plan`; mirror the first one):

```ruby
  it "answers 422 with decK's scrubbed message when deck rejects the rendered YAML" do
    connection = create(:kong_connection, admin_url: "https://kong-admin.test", access_level: "rw", credential_mode: "stored", auth_secret: "devpassword")
    token = token_for(connection)
    plan = create(:change_plan, kong_connection: connection, actor_kind: "agent")
    allow_any_instance_of(Kong::ChangeApplier).to receive(:call)
      .and_raise(Kong::DeckCli::Error, "deck file validate failed: routes.0: name is required\n-----BEGIN PRIVATE KEY-----\nAAAA\n-----END PRIVATE KEY-----")

    post apply_api_v1_change_plan_path(plan), params: { connection: connection.name }, headers: auth(token)

    expect(response).to have_http_status(:unprocessable_entity)
    expect(JSON.parse(response.body)["error"]).to include("name is required")
    expect(response.body).not_to include("AAAA")
  end

  it "answers 502 when the config repo cannot be written" do
    connection = create(:kong_connection, admin_url: "https://kong-admin.test", access_level: "rw", credential_mode: "stored", auth_secret: "devpassword")
    token = token_for(connection)
    plan = create(:change_plan, kong_connection: connection, actor_kind: "agent")
    allow_any_instance_of(Kong::ChangeApplier).to receive(:call).and_raise(Kong::GitClient::Error, "git push failed: remote rejected")

    post apply_api_v1_change_plan_path(plan), params: { connection: connection.name }, headers: auth(token)

    expect(response).to have_http_status(:bad_gateway)
    expect(JSON.parse(response.body)["error"]).to include("git push failed")
  end
```

- [ ] **Step 2: Run and confirm the right failure**

Run: `bundle exec rspec -r "$K" spec/requests/change_plans_spec.rb spec/requests/api/v1/change_plans_spec.rb`

Expected: the four new examples FAIL with the unhandled `Kong::DeckCli::Error` / `Kong::GitClient::Error` propagating (a 500 in a request spec surfaces as the raised error).

- [ ] **Step 3: Implement**

In `app/controllers/change_plans_controller.rb`, add before the existing `rescue NotImplementedError => e`:

```ruby
  rescue Kong::DeckCli::Error, Kong::GitClient::Error => e
    # decK's own message is what an operator needs; the applier has already marked the plan failed.
    redirect_to change_plan_path(@change_plan), alert: Kong::CertificateKeyPolicy.scrub(e.message)
```

In `app/controllers/api/v1/change_plans_controller.rb`, add to `apply`'s rescues, before `rescue NotImplementedError`:

```ruby
      rescue Kong::DeckCli::Error => e
        render json: { error: safe_message(e.message) }, status: :unprocessable_entity
      rescue Kong::GitClient::Error => e
        render json: { error: safe_message(e.message) }, status: :bad_gateway
```

- [ ] **Step 4: Run to green, RuboCop, whole suite**

Run the two request specs — all PASS. `bundle exec rubocop app/controllers/change_plans_controller.rb app/controllers/api/v1/change_plans_controller.rb spec/requests/change_plans_spec.rb spec/requests/api/v1/change_plans_spec.rb` — no offenses. `bundle exec rspec -r "$K"` — 0 failures.

- [ ] **Step 5: Commit**

```bash
git add app/controllers/change_plans_controller.rb app/controllers/api/v1/change_plans_controller.rb spec/requests/change_plans_spec.rb spec/requests/api/v1/change_plans_spec.rb
git commit -m "fix(m5c): show decK and git failures instead of a 500" -m "Neither apply controller rescued DeckCli::Error or GitClient::Error, so decK's own rejection was an unhandled exception. Web redirects back with the scrubbed message; the API answers 422 and 502." -m "Co-Authored-By: Claude Sonnet 5 <noreply@anthropic.com>"
```

---

### Task 8: The review page says who resolves a decK placeholder

**Files:**
- Modify: `app/services/kong/certificate_key_policy.rb`, `spec/services/kong/certificate_key_policy_spec.rb`
- Modify: `app/controllers/change_plans_controller.rb`, `app/views/change_plans/show.html.erb`, `spec/requests/change_plans_spec.rb`

**Interfaces:**
- Consumes: `Kong::CertificateKeyPolicy::KEY_FIELDS`, `.deck_reference?`, the `DECK_REFERENCE` capture group.
- Produces: `Kong::CertificateKeyPolicy.deck_vars_for(change_plan)` → the `DECK_*` variable names a pending PR-mode certificate plan sets or changes (`[]` otherwise); `@deck_env_vars` on `ChangePlansController#show`; a note on the review page.

Why: spec §6 (corrected). A vault reference asks the operator to confirm the variable exists on every Kong node, because Kong will not check. A decK placeholder asks for no confirmation — CI resolves it and an unset variable fails `deck gateway sync` before anything reaches Kong — but the operator should be *told*, or "no checkbox" reads as "nothing to do".

- [ ] **Step 1: Write the failing specs**

Append to `spec/services/kong/certificate_key_policy_spec.rb` inside its outer `RSpec.describe`, before the final `end`:

```ruby
  describe ".deck_vars_for (M5c)" do
    def plan(operation:, after:, diff: {}, entity_type: "certificate", apply_mode: "pr")
      ChangePlan.new(entity_type: entity_type, operation: operation, after: after, diff: diff, apply_mode: apply_mode)
    end

    let(:placeholder) { %q(${{ env "DECK_CERT_PAY_KEY" }}) }

    it "names the variable a PR-mode create sets" do
      expect(described_class.deck_vars_for(plan(operation: "create", after: { "key" => placeholder }))).to eq([ "DECK_CERT_PAY_KEY" ])
    end

    it "names it for an update that changes the key, and not for one that leaves it alone" do
      expect(described_class.deck_vars_for(plan(operation: "update", after: { "key" => placeholder }, diff: { "key" => {} }))).to eq([ "DECK_CERT_PAY_KEY" ])
      expect(described_class.deck_vars_for(plan(operation: "update", after: { "key" => placeholder }, diff: { "tags" => {} }))).to eq([])
    end

    it "is empty for a vault reference (that is what env_vars_for is for), a delete, a direct-mode plan and other types" do
      expect(described_class.deck_vars_for(plan(operation: "create", after: { "key" => "{vault://env/cert-pay-key}" }))).to eq([])
      expect(described_class.deck_vars_for(plan(operation: "delete", after: {}))).to eq([])
      expect(described_class.deck_vars_for(plan(operation: "create", after: { "key" => placeholder }, apply_mode: "direct"))).to eq([])
      expect(described_class.deck_vars_for(plan(operation: "create", after: { "key" => placeholder }, entity_type: "service"))).to eq([])
    end
  end
```

In `spec/requests/change_plans_spec.rb`, add inside `describe "certificates and SNIs (M5b)"` (it has `sign_in`, `connection`, `fixture` and `ref`; mirror `create_cert_plan`):

```ruby
  it "tells the operator CI resolves a decK placeholder, and asks for no acknowledgement" do
    sign_in
    plan = create(:change_plan, kong_connection: connection, apply_mode: "pr", entity_type: "certificate", operation: "create", target_kong_id: nil,
      before: {}, after: { "cert" => fixture[:cert_pem], "key" => %q(${{ env "DECK_CERT_PAY_KEY" }}) },
      diff: { "operation" => "create" }, base_updated_at: nil)

    get change_plan_path(plan)

    expect(response.body).to include("DECK_CERT_PAY_KEY", "CI environment")
    expect(response.body).not_to include("acknowledge_env_vars")
  end

  it "shows no decK note for a vault reference (that one asks for the acknowledgement instead), or for a direct-mode plan" do
    sign_in

    get change_plan_path(create_cert_plan)

    expect(response.body).not_to include("CI environment")
  end
```

- [ ] **Step 2: Run and confirm the right failure**

Run: `bundle exec rspec -r "$K" spec/services/kong/certificate_key_policy_spec.rb spec/requests/change_plans_spec.rb`

Expected: the policy examples FAIL (`undefined method 'deck_vars_for'`); the first request example FAILS (`DECK_CERT_PAY_KEY` not on the page).

- [ ] **Step 3: Implement — the policy**

In `app/services/kong/certificate_key_policy.rb`, directly after `env_vars_for`:

```ruby
    # The decK placeholders a pending PR-mode plan sets or changes. A vault
    # reference is checked by nobody, so env_vars_for asks the operator to
    # confirm it; a placeholder is resolved by CI, where an unset variable makes
    # `deck gateway sync` fail before anything reaches Kong. It needs no
    # acknowledgement -- but the review page says so.
    def self.deck_vars_for(change_plan)
      return [] unless applies_to?(change_plan.entity_type) && change_plan.apply_mode == "pr"

      fields =
        case change_plan.operation
        when "create" then KEY_FIELDS
        when "update" then KEY_FIELDS & change_plan.diff.keys
        else []
        end

      fields.filter_map do |field|
        value = change_plan.after[field]
        DECK_REFERENCE.match(value)[1] if deck_reference?(value)
      end.uniq
    end
```

- [ ] **Step 4: Implement — controller and view**

In `ChangePlansController#show`, next to the `@env_vars` line:

```ruby
    @deck_env_vars = @change_plan.status == "pending" ? Kong::CertificateKeyPolicy.deck_vars_for(@change_plan) : []
```

In `app/views/change_plans/show.html.erb`, immediately after the `<% end %>` that closes `<% if @env_vars.present? %>` (the line before `<% if @requires_confirmation_name %>`), insert:

```erb
<% if @deck_env_vars.present? %>
  <p class="text-xs" style="color: var(--color-ink-faint)">
    decK reads <span class="font-mono"><%= @deck_env_vars.join(", ") %></span> from the CI environment when it syncs this change.
    This tool checked the file with a dummy value and never sees the key. If the variable is unset in CI, the sync fails before anything reaches Kong.
  </p>
<% end %>
```

- [ ] **Step 5: Run to green, RuboCop, whole suite**

Run the two specs — all PASS. `bundle exec rubocop app/services/kong/certificate_key_policy.rb app/controllers/change_plans_controller.rb spec/services/kong/certificate_key_policy_spec.rb spec/requests/change_plans_spec.rb` — no offenses. `bundle exec rspec -r "$K"` — 0 failures.

- [ ] **Step 6: Commit**

```bash
git add app/services/kong/certificate_key_policy.rb spec/services/kong/certificate_key_policy_spec.rb app/controllers/change_plans_controller.rb app/views/change_plans/show.html.erb spec/requests/change_plans_spec.rb
git commit -m "feat(m5c): review page says CI resolves a decK placeholder" -m "A vault reference is checked by nobody, so it asks for an acknowledgement; a decK placeholder is resolved by CI and fails loudly there before Kong is touched, so it asks for none -- but the operator is told." -m "Co-Authored-By: Claude Sonnet 5 <noreply@anthropic.com>"
```

---

### Task 9: Live end-to-end — real decK, real Kong, real git

**Files:**
- Create (outside the repo): `<scratchpad>/e2e_m5c.rb`

**Interfaces:**
- Consumes: everything above, against a **real** temporary Kong 3.7 node, the real `deck` binary and a real bare git repo. **No stubs anywhere** — `Kong::DeckCli` runs the real binary.
- Produces: proof that what the PR proposes is what Kong ends up holding, and a clean machine afterwards.

This is the check that found M5a's millisecond bug and M5b's `snis` bug: mocks encode what we already believe. **Do not skip it, and do not weaken a check to make it pass** — a FAIL is a finding to report with the exact output, and the controller rules on it.

**Safety (binding — the temporary node shares the local stack's Postgres with the user's real Kong):**
- Before starting anything, `curl -s http://localhost:8001/<kind>` for `certificates`, `snis`, `ca_certificates` and `upstreams`. If **any** is non-empty, STOP and report `NEEDS_CONTEXT`; do not proceed and do not delete anything.
- Everything the script creates carries a unique tag (`m5c-e2e-<hex>`) and a name prefix `m5c-e2e-`, and `_info.select_tags` is that tag, so decK can only touch tagged entities.
- **No global plugin** is created (it would apply to the user's real traffic). Plugins are scoped to the script's own service, route and consumer.
- Cleanup deletes only tagged entities and refuses if a planned deletion is not ours. Tear down even when a check fails.
- Use the `kong:3.7` image already present; pull nothing.

- [ ] **Step 1: Start the temporary node**

```bash
export MSYS_NO_PATHCONV=1
for kind in certificates snis ca_certificates upstreams; do printf "%-16s " $kind; curl -s "http://localhost:8001/$kind" | python -c "import sys,json; print(len(json.load(sys.stdin)['data']), 'present')"; done   # all must be 0
D=$(mktemp -d) && echo "$D" > /tmp/m5c_e2e_dir && cd "$D"
openssl req -x509 -newkey rsa:2048 -nodes -keyout key.pem -out cert.pem -days 60 \
  -subj "/CN=e2e.example.internal" -addext "subjectAltName=DNS:e2e.example.internal"
docker rm -f m5c-e2e-kong >/dev/null 2>&1
docker run -d --name m5c-e2e-kong --network kongsole_default \
  -e KONG_DATABASE=postgres -e KONG_PG_HOST=kong-database -e KONG_PG_USER=kong -e KONG_PG_PASSWORD=kong -e KONG_PG_DATABASE=kong \
  -e KONG_ADMIN_LISTEN=0.0.0.0:8001 -e "KONG_PROXY_LISTEN=0.0.0.0:8000, 0.0.0.0:8443 ssl" \
  -e "CERT_E2E_KEY=$(cat key.pem)" -p 8101:8001 -p 8543:8443 kong:3.7
for i in $(seq 1 30); do [ "$(curl -s -o /dev/null -w '%{http_code}' http://localhost:8101/)" = 200 ] && echo "up" && break; sleep 1; done
```

Expected: `0 present` four times, then `up`. The private key exists only in `$D/key.pem` (outside the repo) and in the node's environment as `CERT_E2E_KEY`.

- [ ] **Step 2: Write the script**

Write `<scratchpad>/e2e_m5c.rb` with the Write tool (not a heredoc). The **checks are the specification**; adapt mechanics (a helper's argument, a factory attribute) to the real code if needed, but never a check's meaning.

```ruby
# M5c end to end. Real decK (DECK_BIN), real Kong 3.7 on :8101, real git.
require "open3"
require "net/http"
require "json"
require "securerandom"

DECK = ENV.fetch("DECK_BIN")
DIR = ENV.fetch("M5C_E2E_DIR")
ADMIN = "http://localhost:8101"
TAG = "m5c-e2e-#{SecureRandom.hex(3)}"
CERT_PEM = File.read(File.join(DIR, "cert.pem"))

results = []
check = lambda do |label, ok, detail = nil|
  results << [ label, ok ]
  puts format("%-4s %s%s", ok ? "PASS" : "FAIL", label, detail ? "  -- #{detail}" : "")
end
admin = ->(path) { JSON.parse(Net::HTTP.get(URI("#{ADMIN}#{path}"))) }
deck = lambda do |*args, env: {}|
  out, err, status = Open3.capture3(env, DECK, *args)
  [ status.success?, out, err ]
end
git = lambda do |*args, chdir: DIR|
  out, err, status = Open3.capture3("git", "-c", "user.name=e2e", "-c", "user.email=e2e@example.com", *args, chdir: chdir)
  raise "git #{args.join(' ')}: #{err}" unless status.success?

  out
end

%w[certificates snis ca_certificates upstreams].each do |kind|
  abort "ABORT: #{kind} is not empty on the shared Kong -- refusing to run" unless admin.call("/#{kind}")["data"].empty?
end
puts "tag for this run: #{TAG}"

bare = File.join(DIR, "config.git")
seed = File.join(DIR, "seed")
git.call("init", "--bare", "--initial-branch=main", bare)
git.call("clone", bare, seed)
File.write(File.join(seed, "kong.yaml"), Kong::DeckDocument.serialize(Kong::DeckDocument.parse(nil, select_tags: [ TAG ])))
git.call("add", "-A", chdir: seed)
git.call("commit", "-m", "seed", chdir: seed)
git.call("push", "origin", "main", chdir: seed)

empty_file = File.join(DIR, "empty.yaml")
File.write(empty_file, Kong::DeckDocument.serialize(Kong::DeckDocument.parse(nil, select_tags: [ TAG ])))

cleanup = lambda do
  ok, out, = deck.call("gateway", "diff", empty_file, "--kong-addr", ADMIN, "--json-output")
  entries = ok ? Array(JSON.parse(out).dig("changes", "deleting")) : nil
  ours = entries&.all? do |entry|
    !%w[service route consumer upstream].include?(entry["kind"]) || entry["name"].to_s.start_with?("m5c-e2e-")
  end
  if entries && ours && entries.size <= 40
    deck.call("gateway", "sync", empty_file, "--kong-addr", ADMIN)
    puts "cleanup: removed #{entries.size} tagged entities"
  else
    warn "CLEANUP REFUSED: a planned deletion is not ours (or the diff failed) -- remove #{TAG} entities by hand"
  end
end

begin
  ActiveRecord::Base.transaction do
    connection = KongConnection.create!(
      name: "m5c-e2e", env: "dev", rank: 0, admin_url: ADMIN, auth_type: "basic", auth_username: "e2e", credential_mode: "session",
      apply_mode: "pr", access_level: "ro", writable: false,
      git_repo: bare, git_branch: "main", git_path: "kong.yaml", select_tags: [ TAG ]
    )
    client = Kong::Client.new(connection: connection, secret: nil)

    diff_of = ->(before, after) { after.reject { |key, value| before[key] == value }.transform_values { |value| { "to" => value } } }
    apply_pr = lambda do |entity_type:, operation: "create", before: {}, after: {}, target: nil, parent: nil, ack: false|
      plan = ChangePlan.create!(
        kong_connection: connection, actor_username: "e2e", actor_kind: "human", operation: operation, entity_type: entity_type,
        target_kong_id: target, parent_kong_id: parent, before: before, after: after,
        diff: operation == "update" ? diff_of.call(before, after) : { "operation" => operation },
        apply_mode: "pr", status: "pending", expires_at: 15.minutes.from_now
      )
      Kong::ChangeApplier.new(change_plan: plan, client: client, actor_username: "e2e", secret: "e2e", env_acknowledged: ack).call
      git.call("--git-dir=#{bare}", "update-ref", "refs/heads/main", "refs/heads/kongctl/#{plan.id}")
      plan.reload
    end

    sync_main = lambda do |label, allow_deleting: 0|
      path = File.join(DIR, "main.yaml")
      File.write(path, git.call("--git-dir=#{bare}", "show", "main:kong.yaml"))
      ok, out, err = deck.call("gateway", "diff", path, "--kong-addr", ADMIN, "--json-output")
      check.call("#{label}: deck gateway diff runs on the rendered file", ok, err.lines.first.to_s.strip)
      gate = Kong::CiGate.check(deck_diff: ok ? JSON.parse(out) : {}, admin_path_names: [], delete_threshold: allow_deleting)
      check.call("#{label}: CiGate passes the REAL diff", gate.passed?, gate.reasons.join("; "))
      ok, _out, err = deck.call("gateway", "sync", path, "--kong-addr", ADMIN)
      check.call("#{label}: deck gateway sync applies it to Kong", ok, err.lines.first(2).join(" | ").strip)
      ok, out, = deck.call("gateway", "diff", path, "--kong-addr", ADMIN, "--json-output")
      total = ok ? JSON.parse(out).dig("summary", "total") : nil
      check.call("#{label}: no drift afterwards -- the YAML says exactly what Kong now holds", total == 0, "changes still pending: #{total.inspect}")
    end

    # ---- A. the top-level types, through the real applier -------------------------------------------------
    apply_pr.call(entity_type: "service", after: { "name" => "m5c-e2e-orders", "host" => "orders.internal", "port" => 80, "protocol" => "http", "tags" => [ TAG ] })
    apply_pr.call(entity_type: "upstream", after: { "name" => "m5c-e2e-up", "tags" => [ TAG ] })
    apply_pr.call(entity_type: "consumer", after: { "username" => "m5c-e2e-bot", "tags" => [ TAG ] })
    cert_plan = apply_pr.call(entity_type: "certificate", ack: true,
      after: { "cert" => CERT_PEM, "key" => "{vault://env/cert-e2e-key}", "snis" => [ "e2e.example.internal" ], "tags" => [ TAG ] })
    apply_pr.call(entity_type: "ca_certificate", after: { "cert" => CERT_PEM, "tags" => [ TAG ] })
    minted = cert_plan.target_kong_id
    check.call("the certificate id was minted and stored on the plan", minted.to_s.match?(/\A\h{8}-\h{4}-\h{4}-\h{4}-\h{12}\z/), minted)
    check.call("the audit event records the id and the acknowledged variable",
      AuditEvent.find_by!(change_plan: cert_plan).then { |e| e.target_kong_id == minted && e.context == { "acknowledged_env_vars" => [ "CERT_E2E_KEY" ] } })

    sync_main.call("A (service, upstream, consumer, certificate, CA certificate)")
    check.call("Kong created the certificate under the id the PR proposed", admin.call("/certificates/#{minted}")["id"] == minted)
    check.call("Kong holds the vault reference verbatim, never a PEM key", admin.call("/certificates/#{minted}")["key"] == "{vault://env/cert-e2e-key}")
    check.call("the SNI decK created from the certificate exists and belongs to it", admin.call("/snis/e2e.example.internal").dig("certificate", "id") == minted)
    check.call("service, upstream, consumer and CA certificate exist",
      admin.call("/services/m5c-e2e-orders")["name"] == "m5c-e2e-orders" && admin.call("/upstreams/m5c-e2e-up")["name"] == "m5c-e2e-up" &&
      admin.call("/consumers/m5c-e2e-bot")["username"] == "m5c-e2e-bot" && admin.call("/ca_certificates?tags=#{TAG}")["data"].size == 1)

    # ---- B. children, which need their parents in the read-model ---------------------------------------------
    Kong::EntitySync.sync_connection(connection: connection, client: client)
    svc_id = admin.call("/services/m5c-e2e-orders")["id"]
    up_id = admin.call("/upstreams/m5c-e2e-up")["id"]
    con_id = admin.call("/consumers/m5c-e2e-bot")["id"]

    apply_pr.call(entity_type: "route", after: { "name" => "m5c-e2e-route", "paths" => [ "/m5c-e2e" ], "service" => { "id" => svc_id }, "tags" => [ TAG ] })
    apply_pr.call(entity_type: "target", parent: up_id, after: { "target" => "10.9.9.9:80", "weight" => 100, "tags" => [ TAG ] })
    apply_pr.call(entity_type: "sni", parent: minted, after: { "name" => "b.e2e.example.internal", "certificate" => { "id" => minted }, "tags" => [ TAG ] })
    sync_main.call("B1 (route, target, SNI)")
    route_id = admin.call("/routes/m5c-e2e-route")["id"]
    check.call("the route is nested under its service in Kong", admin.call("/routes/#{route_id}").dig("service", "id") == svc_id)
    check.call("the target is under its upstream", admin.call("/upstreams/#{up_id}/targets")["data"].map { |t| t["target"] } == [ "10.9.9.9:80" ])
    check.call("the second SNI belongs to the certificate", admin.call("/snis/b.e2e.example.internal").dig("certificate", "id") == minted)

    Kong::EntitySync.sync_connection(connection: connection, client: client)
    apply_pr.call(entity_type: "plugin", after: { "name" => "request-size-limiting", "service" => { "id" => svc_id }, "config" => { "allowed_payload_size" => 8 }, "tags" => [ TAG ] })
    apply_pr.call(entity_type: "plugin", after: { "name" => "rate-limiting", "route" => { "id" => route_id }, "config" => { "minute" => 60, "policy" => "local" }, "tags" => [ TAG ] })
    apply_pr.call(entity_type: "plugin", after: { "name" => "cors", "consumer" => { "id" => con_id }, "tags" => [ TAG ] })
    sync_main.call("B2 (service-, route- and consumer-scoped plugins)")
    check.call("the service-scoped plugin is on the service", admin.call("/services/#{svc_id}/plugins")["data"].map { |p| p["name"] } == [ "request-size-limiting" ])
    check.call("the route-scoped plugin is on the route, not the service", admin.call("/routes/#{route_id}/plugins")["data"].map { |p| p["name"] } == [ "rate-limiting" ])
    check.call("the consumer-scoped plugin is on the consumer", admin.call("/consumers/#{con_id}/plugins")["data"].map { |p| p["name"] } == [ "cors" ])

    # ---- C. updates and deletes -----------------------------------------------------------------------------
    Kong::EntitySync.sync_connection(connection: connection, client: client)
    route_before = admin.call("/routes/#{route_id}")
    apply_pr.call(entity_type: "route", operation: "update", target: route_id, before: route_before, after: route_before.merge("paths" => [ "/m5c-e2e-changed" ]))
    target_before = admin.call("/upstreams/#{up_id}/targets")["data"].first
    apply_pr.call(entity_type: "target", operation: "delete", target: target_before["id"], parent: up_id, before: target_before)
    # Order matters: every plan here was proposed against the SAME live Kong state, so the certificate edit (whose
    # `snis` still names both SNIs) must be applied before the SNI delete, or it would put the deleted SNI back.
    cert_before = admin.call("/certificates/#{minted}")
    apply_pr.call(entity_type: "certificate", operation: "update", target: minted, before: cert_before, after: cert_before.merge("tags" => [ TAG, "edited" ]))
    sni_before = admin.call("/snis/b.e2e.example.internal")
    apply_pr.call(entity_type: "sni", operation: "delete", target: sni_before["id"], before: sni_before)
    sync_main.call("C (update route, delete target and SNI, edit certificate tags)", allow_deleting: 3)
    check.call("the route update reached Kong", admin.call("/routes/#{route_id}")["paths"] == [ "/m5c-e2e-changed" ])
    check.call("the target is gone", admin.call("/upstreams/#{up_id}/targets")["data"].empty?)
    check.call("the deleted SNI is gone and the certificate's own SNI remains",
      admin.call("/snis/b.e2e.example.internal")["message"].present? && admin.call("/snis/e2e.example.internal").dig("certificate", "id") == minted)
    check.call("the certificate edit reached Kong and kept its key reference",
      admin.call("/certificates/#{minted}").then { |c| c["tags"].include?("edited") && c["key"] == "{vault://env/cert-e2e-key}" })

    # ---- D. what must be refused, against the real repo ----------------------------------------------------
    branches_before = git.call("--git-dir=#{bare}", "branch", "-a")
    begin
      apply_pr.call(entity_type: "route", after: { "paths" => [ "/x" ], "service" => { "id" => svc_id } })
      check.call("an unnamed route is refused", false, "no error")
    rescue Kong::DeckRenderer::Unrenderable => e
      check.call("an unnamed route is refused, with the repo untouched",
        e.message.include?("needs a name") && git.call("--git-dir=#{bare}", "branch", "-a") == branches_before)
    end
    begin
      apply_pr.call(entity_type: "keyauth_credential", parent: con_id, after: { "key" => "x" })
      check.call("a credential is refused", false, "no error")
    rescue NotImplementedError => e
      check.call("a credential is refused as deliberately never rendered", e.message.include?("deliberately never rendered"))
    end

    raise ActiveRecord::Rollback
  end
ensure
  cleanup.call
end

failed = results.reject(&:last)
puts "\n#{results.size - failed.size}/#{results.size} checks passed"
exit(failed.empty? ? 0 : 1)
```

- [ ] **Step 3: Run it**

```bash
cd /d/kongsole
export DATABASE_URL="postgres://kongsole:kongsole@localhost:5433/kong_integration_test" RAILS_ENV=test
export DECK_BIN="$SP/deck1661/deck.exe"
M5C_E2E_DIR="$(cat /tmp/m5c_e2e_dir)" bin/rails runner "<scratchpad>/e2e_m5c.rb" 2>&1 | grep -vE "warning: |fiddle"
```

Expected: every line `PASS`, ending `N/N checks passed`.

Then repeat the whole run against decK 1.51.1 (`DECK_BIN="$SP/deck1511/deck.exe"`) — start Step 1 fresh first (the previous run's cleanup leaves the node empty, so a second run against the same node is fine; verify the four collections are empty again before it).

If a check FAILs: that is a real finding — do not weaken it, do not edit application code, tear everything down and report the exact failing lines. The likeliest surprises are worth reading for: whether decK wants `tags` on children (SNIs, targets), whether a field this tool renders is rejected by `deck gateway sync` although `file validate` accepted it, and whether "no drift afterwards" fails on a field Kong defaults (which would mean the renderer emits something Kong normalises).

- [ ] **Step 4: Tear down and prove the machine is clean**

```bash
docker rm -f m5c-e2e-kong
rm -rf "$(cat /tmp/m5c_e2e_dir)" /tmp/m5c_e2e_dir
rm -rf storage/git_cache
for kind in snis certificates ca_certificates upstreams; do printf "%-16s " $kind; curl -s "http://localhost:8001/$kind" | python -c "import sys,json; print(len(json.load(sys.stdin)['data']), 'left')"; done
curl -s "http://localhost:8001/services?tags=m5c-e2e" | python -c "import sys,json; print(len(json.load(sys.stdin)['data']), 'tagged services left')"
docker ps -a --format '{{.Names}}' | grep -c m5c-e2e || echo "e2e container: gone"
git status --short
```

(`storage/git_cache` is this tool's per-connection cache of the throwaway repo; check first that it holds nothing but the script's connection's directory — `ls storage/git_cache` — and if it held anything before the run, remove only the directory named for the script's connection id.)

Expected: `0 left` four times, no tagged services, `e2e container: gone`, and `git status --short` showing only the user's pre-existing modifications — **no** `.pem`, `.key`, `.yaml` or scratch files in the repo. If anything of ours remains on the shared Kong, delete it through the Admin API by id and report that the script's cleanup did not fire.

- [ ] **Step 5: Report — nothing to commit**

This task changes no repository file. Report the full PASS/FAIL output for both decK versions, the teardown proof, and any finding.

---

### Task 10: Two things only real decK can answer — the placeholder's PEM, and M5b's unproven Kong edges

**Files:**
- Create (outside the repo): `<scratchpad>/e2e_m5c_placeholder.rb`, `<scratchpad>/e2e_m5c_kong_edges.rb`

**Interfaces:**
- Consumes: the temporary node, `DECK_BIN`, and the safety rules of Task 9 (**same preconditions, same tagged-only cleanup, no global anything**).
- Produces: a table of results the controller rules on. **This is an experiment, not a test suite: it reports, and a "no" is a legitimate answer.**

**Part A — spec §9, the open risk.** With the single-quoted placeholder, decK substitutes the variable as text and the quotes survive. In single quotes YAML does **not** decode `\n`, and a multi-line value cannot sit in a single-quoted scalar at column 0. So it is unknown whether Kong ever receives a usable private key through `key: '${{ env "DECK_X" }}'`. Only a real `deck gateway sync` — where Kong validates that the key matches the cert on write — can say.

**Part B — M5b's final review, item 10.** Three Kong behaviours were only ever stubbed: `PATCH /certificates/:id` with a changed `snis`; `POST /ca_certificates` and its schema validation; an SNI update that re-points its `certificate`.

- [ ] **Step 1: Start the temporary node**

Exactly Task 9 Step 1 (same safety precondition: all four collections empty first).

- [ ] **Step 2: Part A — write and run the placeholder experiment**

Write `<scratchpad>/e2e_m5c_placeholder.rb`:

```ruby
# Which env encodings deliver a usable private key through a decK placeholder? Reports; does not assert.
require "open3"
require "net/http"
require "json"
require "openssl"
require "securerandom"
require "socket"

DECK = ENV.fetch("DECK_BIN")
DIR = ENV.fetch("M5C_E2E_DIR")
ADMIN = "http://localhost:8101"
TAG = "m5c-e2e-#{SecureRandom.hex(3)}"
CERT_PEM = File.read(File.join(DIR, "cert.pem"))
KEY_PEM = File.read(File.join(DIR, "key.pem"))
EXPECTED_FP = OpenSSL::Digest::SHA256.hexdigest(OpenSSL::X509::Certificate.new(CERT_PEM).to_der)
CERT_ID = SecureRandom.uuid

admin = ->(path) { JSON.parse(Net::HTTP.get(URI("#{ADMIN}#{path}"))) }
%w[certificates snis ca_certificates upstreams].each do |kind|
  abort "ABORT: #{kind} is not empty on the shared Kong" unless admin.call("/#{kind}")["data"].empty?
end

served = lambda do
  tcp = TCPSocket.new("localhost", 8543)
  ctx = OpenSSL::SSL::SSLContext.new
  ctx.verify_mode = OpenSSL::SSL::VERIFY_NONE
  ssl = OpenSSL::SSL::SSLSocket.new(tcp, ctx)
  ssl.hostname = "e2e.example.internal"
  ssl.connect
  OpenSSL::Digest::SHA256.hexdigest(ssl.peer_cert.to_der)
rescue OpenSSL::SSL::SSLError, SystemCallError => e
  "error: #{e.class}"
ensure
  ssl&.close
  tcp&.close
end

cert_block = CERT_PEM.lines.map { |line| "        #{line}" }.join
document = lambda do |key_line|
  <<~YAML
    _format_version: '3.0'
    _info:
      select_tags:
        - #{TAG}
    certificates:
      - id: #{CERT_ID}
        cert: |
    #{cert_block}
        key: #{key_line}
        snis:
          - name: e2e.example.internal
        tags:
          - #{TAG}
  YAML
end

single = %q('${{ env "DECK_E2E_KEY" }}')
double = %q("${{ env "DECK_E2E_KEY" }}")
variants = {
  "a  single-quoted placeholder, value with literal \\n escapes" => [ single, KEY_PEM.strip.gsub("\n", "\\n") ],
  "b  single-quoted placeholder, value with real newlines" => [ single, KEY_PEM ],
  "c  DOUBLE-quoted placeholder, value with literal \\n escapes" => [ double, KEY_PEM.strip.gsub("\n", "\\n") ]
}

empty = File.join(DIR, "empty.yaml")
File.write(empty, "_format_version: '3.0'\n_info:\n  select_tags:\n    - #{TAG}\n")

puts format("%-64s %-9s %-9s %-11s %s", "variant", "validate", "sync", "key stored", "TLS serves our cert")
puts "-" * 118
variants.each do |label, (key_line, value)|
  path = File.join(DIR, "placeholder.yaml")
  File.write(path, document.call(key_line))
  env = { "DECK_E2E_KEY" => value }
  v_ok, _o, v_err = Open3.capture3(env, DECK, "file", "validate", path).then { |o, e, s| [ s.success?, o, e ] }
  s_ok, _o, s_err = Open3.capture3(env, DECK, "gateway", "sync", path, "--kong-addr", ADMIN).then { |o, e, s| [ s.success?, o, e ] }
  stored = s_ok ? admin.call("/certificates/#{CERT_ID}")["key"].to_s : ""
  key_ok = s_ok && stored.strip == KEY_PEM.strip
  tls = s_ok ? (served.call == EXPECTED_FP ? "yes" : served.call) : "n/a"
  puts format("%-64s %-9s %-9s %-11s %s", label, v_ok ? "ok" : "FAIL", s_ok ? "ok" : "FAIL", s_ok ? (key_ok ? "exact" : "DIFFERS") : "n/a", tls)
  puts "    validate: #{v_err.lines.first.to_s.strip[0, 140]}" unless v_ok
  puts "    sync:     #{s_err.lines.first(2).join(' ').strip[0, 200]}" unless s_ok
  Open3.capture3(DECK, "gateway", "sync", empty, "--kong-addr", ADMIN) # remove what this variant created
  sleep 2
end
puts "\nremaining after cleanup: certificates=#{admin.call('/certificates')['data'].size} snis=#{admin.call('/snis')['data'].size}"
```

Run: `M5C_E2E_DIR="$(cat /tmp/m5c_e2e_dir)" DECK_BIN="$SP/deck1661/deck.exe" ruby <scratchpad>/e2e_m5c_placeholder.rb` — and again with `deck1511`. (Plain Ruby; it needs no Rails.) Expected final line: `remaining … certificates=0 snis=0`; if not, remove what is left by id through the Admin API (the tagged certificate only).

**Record the table verbatim.** How to read it:
- A variant that is `ok / ok / exact / yes` **delivers a usable key** through that form.
- Only forms this tool can *write* matter: `single` (both a and b) is what `Kong::DeckDocument` emits today; `double` is not parseable by Ruby's YAML (spec §1.5) and would need a sentinel pre-substitution in `DeckDocument.parse`. If **only** `c` works, that is a design decision for the controller (implement the sentinel, or withdraw), not for this task.

- [ ] **Step 3: Part B — write and run the Kong edges**

Write `<scratchpad>/e2e_m5c_kong_edges.rb`:

```ruby
# M5b's mock-only assumptions, against real Kong 3.7 (direct Admin API on the temporary node). Reports; does not assert.
require "net/http"
require "json"
require "securerandom"

DIR = ENV.fetch("M5C_E2E_DIR")
CERT_PEM = File.read(File.join(DIR, "cert.pem"))
TAG = "m5c-e2e-#{SecureRandom.hex(3)}"
BASE = URI("http://localhost:8101")

def call(verb, path, body = nil)
  req = Net::HTTP.const_get(verb.to_s.capitalize).new(path, "Content-Type" => "application/json")
  req.body = body.to_json if body
  res = Net::HTTP.start(BASE.host, BASE.port) { |http| http.request(req) }
  [ res.code.to_i, (JSON.parse(res.body) rescue nil) ]
end

%w[certificates snis ca_certificates upstreams].each { |kind| abort "ABORT: #{kind} not empty" unless call(:get, "/#{kind}")[1]["data"].empty? }

created = []
report = ->(label, value) { puts format("%-78s %s", label, value) }
begin
  code, one = call(:post, "/certificates", { cert: CERT_PEM, key: "{vault://env/cert-e2e-key}", snis: [ "one.e2e.example.internal" ], tags: [ TAG ] })
  report.call("POST /certificates with snis and a vault-reference key", code)
  created << [ "/certificates", one["id"] ] if one

  code, patched = call(:patch, "/certificates/#{one['id']}", { snis: [ "one.e2e.example.internal", "two.e2e.example.internal" ] })
  report.call("PATCH /certificates/:id with a CHANGED snis", "#{code} -> snis now #{patched.is_a?(Hash) ? patched['snis'].inspect : patched.inspect}")

  code, body = call(:post, "/schemas/ca_certificates/validate", { cert: CERT_PEM, tags: [ TAG ] })
  report.call("POST /schemas/ca_certificates/validate with a valid cert", "#{code} #{body.inspect[0, 90]}")
  code, body = call(:post, "/schemas/ca_certificates/validate", { cert: "not a pem" })
  report.call("POST /schemas/ca_certificates/validate with a bad cert", "#{code} #{body.inspect[0, 90]}")
  code, ca = call(:post, "/ca_certificates", { cert: CERT_PEM, tags: [ TAG ] })
  report.call("POST /ca_certificates", "#{code} keys=#{ca.is_a?(Hash) ? ca.keys.sort.inspect[0, 90] : ca.inspect}")
  created << [ "/ca_certificates", ca["id"] ] if ca.is_a?(Hash) && ca["id"]

  code, two = call(:post, "/certificates", { cert: CERT_PEM, key: "{vault://env/cert-e2e-key}", snis: [ "other.e2e.example.internal" ], tags: [ TAG ] })
  created << [ "/certificates", two["id"] ] if two.is_a?(Hash) && two["id"]
  code, repointed = call(:patch, "/snis/one.e2e.example.internal", { certificate: { id: two["id"] } })
  report.call("PATCH /snis/:name re-pointing its certificate", "#{code} -> now on #{repointed.is_a?(Hash) ? repointed.dig('certificate', 'id') == two['id'] ? 'the other certificate' : 'the SAME certificate' : repointed.inspect}")
  code, after = call(:get, "/certificates/#{one['id']}")
  report.call("the old certificate's snis after the re-point", after.is_a?(Hash) ? after["snis"].inspect : code)
ensure
  # Deleting a certificate cascades its SNIs.
  created.reverse_each { |path, id| call(:delete, "#{path}/#{id}") }
  %w[certificates snis ca_certificates].each { |kind| report.call("left over on #{kind}", call(:get, "/#{kind}")[1]["data"].size) }
end
```

Run: `M5C_E2E_DIR="$(cat /tmp/m5c_e2e_dir)" ruby <scratchpad>/e2e_m5c_kong_edges.rb`. Every `left over` line must be `0`; if not, delete the tagged leftovers by id.

**Record the output verbatim.** Each line answers a stubbed assumption: does Kong accept `snis` on a PATCH, does `POST /ca_certificates` (and its schema check) behave the way `Kong::ChangePlanner` assumes, and can an SNI be re-pointed.

- [ ] **Step 4: Tear down**

Exactly Task 9 Step 4 (the node, the temp dir, the four collections back to `0 left`, `git status` clean).

- [ ] **Step 5: Report — nothing to commit**

Report both tables verbatim for both decK versions (Part A) and the Part B output. State plainly, for Part A, which variants delivered an `exact` key with `TLS serves our cert = yes`. **Do not change any application code.** The controller decides what the result means for `Kong::CertificateKeyPolicy` (spec §9: if no form this tool can write delivers a usable key, the decK placeholder path is withdrawn for private keys and vault references remain).

---

### Task 11: Documentation and final verification

**Files:**
- Modify: `README.md`, `docs/DESIGN.md`, `docs/DESIGN.html`

**Interfaces:**
- Consumes: everything above, and the recorded results of Tasks 9 and 10 (the controller supplies the outcome of Task 10 Part A in the dispatch; write the placeholder paragraph to match it).
- Produces: documentation that matches what the code now does, a clean repo, and the final verification evidence.

- [ ] **Step 1: README**

Add a section after "Certificates, SNIs and CA certificates (M5b)":

```markdown
## PR mode and decK (M5c)

In PR mode (`apply_mode: pr`) every managed type except credentials is rendered into the connection's decK YAML
(`docs/DESIGN.md` section 6; design and the decK findings in
`docs/superpowers/specs/2026-09-21-m5c-deck-rendering-design.md`): services, routes, plugins, upstreams, targets,
certificates, SNIs, CA certificates and consumers. Children are nested inside their parent, the way `deck gateway dump`
writes them. **Consumer credentials are never rendered** (decK would sync their password hashes back and break logins);
a PR-mode plan for one is refused with a message saying so.

- **The config file must be in the tool's own format.** The tool checks that re-rendering the file would reproduce it
  byte for byte, and refuses if not — comments, YAML anchors and hand formatting cannot be preserved, and
  `deck gateway sync` deletes whatever is absent from the file. Keys it does not manage (`vaults`, `consumer_groups`,
  flat `routes`) are kept as they are. A repo seeded by `rake kong:seed` before M5c has a bare `services:` line that decK
  itself rejects; it is accepted once and dropped on the next render.
- **decK must be installed** on the machine that applies (tested with 1.51.1 and 1.66.1). Set `DECK_BIN` to use a binary
  that is not on `PATH`. The tool runs `deck file validate` (offline) and `deck gateway diff` (read-only credential).
- **The tool never sees a private key.** A certificate's `key` is a vault reference, or in PR mode a decK placeholder
  `'${{ env "DECK_CERT_X_KEY" }}'` which **CI** resolves. To check the file, the tool sets a dummy value for each such variable.
  An unset variable in CI fails `deck gateway sync` before anything reaches Kong.
- A certificate created through PR mode gets a UUID from the tool (decK requires an id on certificates); it is recorded
  on the change plan and in the audit event, and is the id Kong ends up with.
- A change the tool cannot render faithfully is refused before the repo is touched: a route with no name (decK requires
  one), a child whose parent is not in the file, or a certificate update whose entry has no matching id.
```

Then add the placeholder outcome from Task 10 Part A (if the controller ruled the placeholder path withdrawn for private keys, replace the third bullet accordingly and say vault references are the supported route).

- [ ] **Step 2: DESIGN.md and DESIGN.html**

In `docs/DESIGN.md` §15 mark M5c and record what was measured. Add (Thai, matching the surrounding style) under the M5 milestone:

```markdown
**M5c — decK render ทุก type (เสร็จ):** render service, route, plugin, upstream, target, certificate, sni, ca_certificate และ consumer ลง decK YAML แบบ nested เหมือน `deck gateway dump` · credential ไม่ render เด็ดขาด (ข้อ 1.7) · ตรวจกับ decK จริง **1.51.1 และ 1.66.1 — ผลตรงกันทุกข้อ** จึงปิดคำถามข้อ 6 ("decK เวอร์ชันไหน") สำหรับ format นี้ · สิ่งที่วัดได้: decK ไม่รับ `-s` (ไฟล์เป็น positional), `deck gateway validate` เป็น online (offline คือ `deck file validate`), schema ปิด (key/field ที่ไม่รู้จักถูกปฏิเสธ), ต้องมี `id` เฉพาะ certificate และ `name` เฉพาะ route, ไม่รับค่า `null`, target ต้อง nested ใต้ upstream · `Kong::DeckCli` และ `Kong::CiGate` ก่อนหน้านี้ผิดทั้งคู่กับ output จริงและไม่เคยถูกรันเพราะถูก stub (แก้แล้ว)
```

Add the equivalent short paragraph to `docs/DESIGN.html` inside the matching M5 block (find the paragraph mentioning `M5b` or `kong_certs_expiring` and append a sibling with the same markup class that section uses — check with a neighbouring paragraph — using `<code>` for identifiers). Also, wherever DESIGN.md §1.2 / iron rule ค is described, add one sentence: the round-trip rule is enforced on the **input** file (`Kong::DeckDocument.verify_input!`), not only on the output.

Line endings: these three files are edited with the Edit tool; confirm with a Ruby count before/after that each is still fully CRLF and that `git diff --numstat` shows only added lines (no whole-file rewrite).

- [ ] **Step 3: Final verification — evidence before claims**

```bash
export DATABASE_URL="postgres://kongsole:kongsole@localhost:5433/kong_integration_test"
K="C:/Users/66880/AppData/Local/Temp/claude/d--kongsole/06b4608a-a6d3-494b-8684-2c796edce238/scratchpad/test_encryption_keys.rb"
bundle exec rspec -r "$K" 2>&1 | grep -E "^rspec|examples,"                    # expect 0 failures
DECK_BIN="$SP/deck1661/deck.exe" bundle exec rspec -r "$K" spec/services/kong/deck_cli_spec.rb 2>&1 | grep -E "examples,"   # real-binary examples included
DECK_BIN="$SP/deck1511/deck.exe" bundle exec rspec -r "$K" spec/services/kong/deck_cli_spec.rb 2>&1 | grep -E "examples,"
bundle exec rspec 2>&1 | grep -E "Missing Active Record" | sort | uniq -c      # as-is: only that environment error
bundle exec rubocop 2>&1 | grep -E "inspected"                                 # expect no offenses
bundle exec brakeman -q --no-pager 2>&1 | grep -E "Security Warnings"          # expect 0
grep -rn "DeckRenderer\.\(parse\|serialize\)" app spec lib bin                 # expect no output
git status --short
```

Expected: 0 failures with keys supplied; the as-is failures are **only** `Missing Active Record encryption credential`; both real-binary runs of `deck_cli_spec.rb` green; RuboCop clean; Brakeman `0`; no `DeckRenderer.parse/serialize` left; `git status` lists only the user's three pre-existing modifications and the docs you edited. The MCP server is untouched by M5c, so its suite is not re-run; say so.

Then report honestly: what passed; what the environment prevents (the encryption keys); the M5b findings still open (`mcp/src/config.ts` hardcoded token, untouched); what Tasks 9 and 10 found; and the items under "Noticed, deliberately not taken".

- [ ] **Step 4: Commit**

```bash
git add README.md docs/DESIGN.md docs/DESIGN.html
git commit -m "docs(m5c): PR mode renders every managed type; decK findings recorded" -m "Co-Authored-By: Claude Sonnet 5 <noreply@anthropic.com>"
```

