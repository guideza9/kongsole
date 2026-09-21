# M5b — Certificates, SNIs, CA certificates, private key on env: Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Manage `certificate`, `sni` and `ca_certificate` through the existing plan → review → apply → audit pipeline, with a private key that only ever exists as an environment variable on Kong's nodes.

**Architecture:** Three flat entity types join `Kong::EntityTypes`. A new `Kong::CertificateKeyPolicy` is the single authority on what a certificate `key` may contain (a `{vault://env/NAME}` reference, or in PR mode a decK `${{ env "DECK_NAME" }}` placeholder); `Kong::ChangePlanner` enforces it for every surface and `Kong::ChangeApplier` re-checks it and demands an explicit acknowledgement that the env var exists. `Kong::EntitySync` caches certificate *metadata* (parsed from the PEM by `Kong::CertificateMetadata`), never the PEM, and fills the existing `kong_entities.not_after` column that powers an expiry dashboard and an MCP tool.

**Tech Stack:** Rails 8.1, RSpec + WebMock + FactoryBot, Ruby `OpenSSL`, Postgres jsonb, Hotwire/ERB views, TypeScript MCP server (vitest, zod).

**Spec:** `docs/superpowers/specs/2026-09-21-m5b-certificates-snis-design.md` (read it first — section 1 records the Kong 3.7.1 behaviours this plan relies on).

## Global Constraints

- Kong version under test is **3.7.1 CE**; its `env` vault backend is `vaults: ["bundled"]`.
- `{vault://env/cert-payments-key}` reads the env var **`CERT_PAYMENTS_KEY`** (uppercase, `-` → `_`).
- Kong does **not** validate a vault reference on write (a missing variable and a non-matching key both return 201) and a missing variable causes a hard TLS failure (`tlsv1 alert internal error`). Never claim the tool can verify a reference.
- A private key (PEM) is **never** accepted, stored, logged, echoed back, or returned by any surface. Rejection is loud (an error), never a silent drop.
- `${{ env "DECK_NAME" }}` is accepted **only** when the connection's `apply_mode` is `pr`. PR-mode plans for these types still raise `NotImplementedError` (rendering is M5c).
- Only a plan that **sets or changes** a vault-referenced key needs the env-var acknowledgement.
- The read-model caches certificate **metadata only** (subject, issuer, serial, not_before, not_after, fingerprint_sha256, sans) under `data["_metadata"]`; the `cert`/`cert_alt` PEMs are dropped. A PEM that fails to parse must **never** fail a sync.
- Expiry tiers: `expired` (past), `critical` (≤ 7 days), `warning` (≤ 30 days), `ok`, and `nil` when there is no `not_after`.
- Web expiry dashboard is scoped to the **current connection**; the REST API and MCP tool cover every connection the token can reach.
- Working tree uses **CRLF**. After creating a new file run `sed -i 's/\r$//; s/$/\r/' <file>`. Prefer the Edit tool for existing files (it preserves CRLF).
- Error mapping: anything malformed is a `Kong::ChangePlanner::InvalidChange` subclass (web re-renders with the operator's text, API answers **422**); guardrail refusals stay plain `Kong::ChangeGuardrails::Violation` (API **403**).
- **Commits:** the steps below name a commit for each task. Only run them if the user has asked for commits in this session; otherwise skip the commit step and leave changes in the working tree.
- Do not touch `mcp/src/config.ts` (it holds a hardcoded token that is out of scope) or the already-modified `.gitattributes`, `Gemfile.lock`, `config/database.yml`.

## Running tests on this machine

Two environment gaps predate M5b; work around them, do not "fix" the repo:

```bash
export DATABASE_URL="postgres://kongsole:kongsole@localhost:5433/kong_integration_test"
# encrypted credentials can't be decrypted here (no config/master.key); throwaway keys, kept OUTSIDE the repo:
K="C:/Users/66880/AppData/Local/Temp/claude/d--kongsole/06b4608a-a6d3-494b-8684-2c796edce238/scratchpad/test_encryption_keys.rb"
bundle exec rspec -r "$K" <paths>        # baseline before M5b: 328 examples, 0 failures
```

Without `-r "$K"` any spec creating a `credential_mode: "stored"` connection fails with `Missing Active Record encryption credential` — that is the environment, not your change. MCP: `cd mcp && npx vitest run` (one pre-existing failure in `config.test.ts`, the hardcoded token) and `npx tsc --noEmit -p .`.

Long shell heredocs are rejected by this environment's Bash tool. Write files with the Write/Edit tools, or write a script file first and run it.

## File Structure

**Create**
- `app/services/kong/certificate_key_policy.rb` — the one authority on what a `key`/`key_alt` may hold; env var naming; env vars a plan needs acknowledged; PEM scrubbing for echoed text.
- `app/services/kong/certificate_metadata.rb` — parses a PEM into the metadata hash the read-model stores.
- `spec/support/pem_fixtures.rb` — generates real self-signed certificates for specs (required explicitly, `spec/support` is not auto-loaded).
- `db/migrate/<ts>_add_context_to_audit_events.rb` — nullable-by-default `jsonb` `context` column.
- `app/controllers/certificates_controller.rb` + `app/views/certificates/expiring.html.erb` — web expiry dashboard (current connection).
- `app/controllers/api/v1/certificates_controller.rb` — `GET /api/v1/certificates/expiring`.
- Specs mirroring each of the above.

**Modify**
- `app/services/kong/redactor.rb` — `key_alt`; vault/deck references pass through for `certificate`.
- `app/services/kong/entity_types.rb` — three types, `parent_in_body`, `label` learns a certificate's first SNI.
- `app/services/kong/entity_sync.rb` — identity, metadata, sync order for the new types.
- `app/models/kong_entity.rb` — `expiry_status`, `expiring_within` scope.
- `app/services/kong/change_planner.rb` — policy enforcement, SNI parent handling, validation body.
- `app/services/kong/change_applier.rb` — policy re-check, acknowledgement, audit context, write-through and cascade.
- `app/controllers/concerns/json_payload_parsing.rb` — never silently prune a certificate key.
- `app/controllers/entities_controller.rb`, `app/controllers/change_plans_controller.rb`, `app/controllers/api/v1/change_plans_controller.rb`, `config/routes.rb`, `config/initializers/filter_parameter_logging.rb`.
- `app/helpers/application_helper.rb`, `app/helpers/entities_helper.rb` and the `entities/`, `change_plans/` views.
- `mcp/src/client.ts`, `mcp/src/tools.ts` (+ their tests), `README.md`, `docs/DESIGN.md`.

---

### Task 1: `Kong::CertificateKeyPolicy`

**Files:**
- Create: `app/services/kong/certificate_key_policy.rb`
- Test: `spec/services/kong/certificate_key_policy_spec.rb`

**Interfaces:**
- Consumes: `Kong::ChangePlanner::InvalidChange` (exists, M5a), `Kong::Redactor::MARK` (`"[REDACTED]"`).
- Produces (later tasks call these exact names):
  - `Kong::CertificateKeyPolicy::Rejected < Kong::ChangePlanner::InvalidChange`
  - `.applies_to?(entity_type) -> Boolean` (true only for `"certificate"`)
  - `.vault_reference?(value) -> Boolean`, `.deck_reference?(value) -> Boolean`, `.reference?(value) -> Boolean`
  - `.env_var_name(value) -> String | nil`
  - `.check!(attributes, entity_type:, apply_mode:, operation: nil) -> nil` (raises `Rejected`)
  - `.env_vars_for(change_plan) -> Array<String>`
  - `.scrub(text) -> String`
  - `KEY_FIELDS = %w[key key_alt]`

- [ ] **Step 1: Write the failing test**

Create `spec/services/kong/certificate_key_policy_spec.rb`:

```ruby
require "rails_helper"

RSpec.describe Kong::CertificateKeyPolicy do
  let(:pem_key) { "-----BEGIN PRIVATE KEY-----\nMIIEvQIBADANBgkqhkiG9w0B\n-----END PRIVATE KEY-----\n" }

  describe ".applies_to?" do
    it "is true for a certificate and nothing else" do
      expect(described_class.applies_to?("certificate")).to be(true)
      %w[ca_certificate sni keyauth_credential service].each do |type|
        expect(described_class.applies_to?(type)).to be(false)
      end
    end
  end

  describe "references" do
    it "recognises a vault env reference" do
      expect(described_class.vault_reference?("{vault://env/cert-payments-key}")).to be(true)
    end

    it "rejects lookalikes: other vaults, uppercase names, trailing text, no name" do
      [ "{vault://hcv/secret/key}", "{vault://env/Cert-Key}", "{vault://env/x} ", "{vault://env/}", "vault://env/x", pem_key, nil, 5 ].each do |bad|
        expect(described_class.vault_reference?(bad)).to be(false), "expected #{bad.inspect} not to be a reference"
      end
    end

    it "recognises a decK env placeholder only for DECK_ names" do
      expect(described_class.deck_reference?('${{ env "DECK_CERT_PAYMENTS_KEY" }}')).to be(true)
      expect(described_class.deck_reference?('${{ env "HOME" }}')).to be(false)
    end

    it "treats either form as a reference" do
      expect(described_class.reference?("{vault://env/a}")).to be(true)
      expect(described_class.reference?('${{ env "DECK_A" }}')).to be(true)
      expect(described_class.reference?("plain")).to be(false)
    end
  end

  describe ".env_var_name" do
    it "uppercases a vault name and turns dashes into underscores (verified against Kong 3.7.1)" do
      expect(described_class.env_var_name("{vault://env/cert-payments-key}")).to eq("CERT_PAYMENTS_KEY")
    end

    it "returns the DECK_ name of a decK placeholder as-is" do
      expect(described_class.env_var_name('${{ env "DECK_CERT_A" }}')).to eq("DECK_CERT_A")
    end

    it "is nil for anything that is not a reference" do
      expect(described_class.env_var_name(pem_key)).to be_nil
    end
  end

  describe ".check!" do
    def check(attrs, apply_mode: "direct", operation: nil, entity_type: "certificate")
      described_class.check!(attrs, entity_type: entity_type, apply_mode: apply_mode, operation: operation)
    end

    it "is a no-op for any type but certificate, even with a PEM in a key field" do
      expect { check({ "key" => pem_key }, entity_type: "keyauth_credential") }.not_to raise_error
      expect { check({ "key" => pem_key }, entity_type: "ca_certificate") }.not_to raise_error
    end

    it "accepts a vault reference in key and key_alt in both apply modes" do
      %w[direct pr].each do |mode|
        expect { check({ "key" => "{vault://env/a}", "key_alt" => "{vault://env/b}" }, apply_mode: mode) }.not_to raise_error
      end
    end

    it "accepts a decK placeholder in PR mode" do
      expect { check({ "key" => '${{ env "DECK_A" }}' }, apply_mode: "pr") }.not_to raise_error
    end

    it "rejects a decK placeholder in direct mode -- nothing would inject it" do
      expect { check({ "key" => '${{ env "DECK_A" }}' }, apply_mode: "direct") }
        .to raise_error(described_class::Rejected, /direct/)
    end

    it "rejects a PEM loudly, naming the field and the fix, and never echoing the key" do
      expect { check({ "key" => pem_key }) }.to raise_error(described_class::Rejected) { |e|
        expect(e).to be_a(Kong::ChangePlanner::InvalidChange)
        expect(e.message).to include("key")
        expect(e.message).to include("{vault://env/")
        expect(e.message).not_to include("MIIEvQIBADANBgkqhkiG9w0B")
        expect(e.message).not_to include("BEGIN PRIVATE KEY")
      }
    end

    it "rejects key_alt the same way" do
      expect { check({ "key_alt" => "not-a-reference" }) }.to raise_error(described_class::Rejected, /key_alt/)
    end

    it "lets nil through (clearing key_alt) and skips the inherited redaction marker" do
      expect { check({ "key_alt" => nil }) }.not_to raise_error
      expect { check({ "key" => Kong::Redactor::MARK }) }.not_to raise_error
    end

    it "requires a key on create, but not on update" do
      expect { check({ "snis" => [ "a.example" ] }, operation: "create") }.to raise_error(described_class::Rejected, /needs a key/)
      expect { check({ "tags" => [ "x" ] }, operation: "update") }.not_to raise_error
    end
  end

  describe ".env_vars_for" do
    def plan(operation:, after:, diff: {})
      build(:change_plan, entity_type: "certificate", operation: operation, after: after, diff: diff)
    end

    it "lists the variables a create sets" do
      p = plan(operation: "create", after: { "key" => "{vault://env/cert-a-key}", "key_alt" => "{vault://env/cert-b-key}" })
      expect(described_class.env_vars_for(p)).to eq(%w[CERT_A_KEY CERT_B_KEY])
    end

    it "lists only the key fields an update actually changes" do
      p = plan(operation: "update", after: { "key" => "{vault://env/cert-a-key}", "tags" => %w[x] },
        diff: { "tags" => { "from" => [], "to" => %w[x] } })
      expect(described_class.env_vars_for(p)).to eq([])

      p = plan(operation: "update", after: { "key" => "{vault://env/cert-new}" },
        diff: { "key" => { "from" => "{vault://env/cert-old}", "to" => "{vault://env/cert-new}" } })
      expect(described_class.env_vars_for(p)).to eq(%w[CERT_NEW])
    end

    it "is empty for a delete, a decK placeholder, and any other entity type" do
      expect(described_class.env_vars_for(plan(operation: "delete", after: {}))).to eq([])
      expect(described_class.env_vars_for(plan(operation: "create", after: { "key" => '${{ env "DECK_A" }}' }))).to eq([])
      other = build(:change_plan, entity_type: "sni", operation: "create", after: { "key" => "{vault://env/x}" })
      expect(described_class.env_vars_for(other)).to eq([])
    end
  end

  describe ".scrub" do
    it "replaces a private key block so it is never echoed back to the browser" do
      text = %({"key": "#{pem_key.gsub("\n", '\n')}"})
      body = "before\n#{pem_key}after"

      expect(described_class.scrub(body)).to eq("before\n[private key removed]\nafter")
      expect(described_class.scrub(text)).not_to include("MIIEvQIBADANBgkqhkiG9w0B")
    end

    it "leaves a certificate (public) block and ordinary text alone" do
      cert = "-----BEGIN CERTIFICATE-----\nAAAA\n-----END CERTIFICATE-----"
      expect(described_class.scrub(cert)).to eq(cert)
      expect(described_class.scrub(nil)).to eq("")
    end
  end
end
```

- [ ] **Step 2: Run the test to verify it fails**

Run: `bundle exec rspec -r "$K" spec/services/kong/certificate_key_policy_spec.rb`
Expected: FAIL / error `uninitialized constant Kong::CertificateKeyPolicy`.

- [ ] **Step 3: Write the minimal implementation**

Create `app/services/kong/certificate_key_policy.rb`:

```ruby
module Kong
  # The one authority on what a certificate's `key` / `key_alt` may hold --
  # docs/DESIGN.md section 8 and the M5b spec (section 3). A private key is
  # never accepted by this tool; it lives as an environment variable on
  # Kong's nodes and a certificate only *references* it.
  #
  #   {vault://env/cert-payments-key}    any apply mode. Kong reads the env
  #                                      var CERT_PAYMENTS_KEY at runtime.
  #   ${{ env "DECK_CERT_PAYMENTS_KEY" }} PR mode only. decK substitutes it
  #                                      when CI syncs; in direct mode nothing
  #                                      would, so the literal string would be
  #                                      written into Kong.
  #
  # Anything else is rejected loudly -- never silently dropped, which would
  # leave an operator believing a key was set when it was not.
  module CertificateKeyPolicy
    class Rejected < Kong::ChangePlanner::InvalidChange; end

    KEY_FIELDS = %w[key key_alt].freeze
    VAULT_REFERENCE = %r{\A\{vault://env/([a-z0-9][a-z0-9_-]*)\}\z}
    DECK_REFERENCE = /\A\$\{\{ env "(DECK_[A-Z0-9_]+)" \}\}\z/
    PRIVATE_KEY_BLOCK = /-----BEGIN [A-Z ]*PRIVATE KEY-----.*?-----END [A-Z ]*PRIVATE KEY-----/m
    EXAMPLE = "{vault://env/cert-payments-key}".freeze

    def self.applies_to?(entity_type)
      entity_type.to_s == "certificate"
    end

    def self.vault_reference?(value)
      value.is_a?(String) && VAULT_REFERENCE.match?(value)
    end

    def self.deck_reference?(value)
      value.is_a?(String) && DECK_REFERENCE.match?(value)
    end

    def self.reference?(value)
      vault_reference?(value) || deck_reference?(value)
    end

    # The env var Kong (vault) or decK (placeholder) will read. Verified
    # against Kong 3.7.1: cert-payments-key -> CERT_PAYMENTS_KEY.
    def self.env_var_name(value)
      if (match = VAULT_REFERENCE.match(value.to_s)) && vault_reference?(value)
        match[1].upcase.tr("-", "_")
      elsif (match = DECK_REFERENCE.match(value.to_s)) && deck_reference?(value)
        match[1]
      end
    end

    def self.check!(attributes, entity_type:, apply_mode:, operation: nil)
      return unless applies_to?(entity_type)

      attributes ||= {}
      if operation == "create" && attributes["key"].blank?
        raise Rejected, "a certificate needs a key reference, e.g. #{EXAMPLE} (read from CERT_PAYMENTS_KEY on every Kong node)"
      end

      KEY_FIELDS.each do |field|
        next unless attributes.key?(field)

        value = attributes[field]
        next if value.nil? || value == Kong::Redactor::MARK
        next if vault_reference?(value)
        next if apply_mode == "pr" && deck_reference?(value)

        raise Rejected, rejection_message(field, value, apply_mode)
      end
    end

    # Env vars a plan will make Kong read, for the acknowledgement. Only a
    # plan that sets or changes a *vault* reference counts -- a tags edit or a
    # delete needs no confirmation, and a decK placeholder is CI's concern.
    def self.env_vars_for(change_plan)
      return [] unless applies_to?(change_plan.entity_type)

      fields =
        case change_plan.operation
        when "create" then KEY_FIELDS
        when "update" then KEY_FIELDS & change_plan.diff.keys
        else []
        end

      fields.filter_map do |field|
        value = change_plan.after[field]
        env_var_name(value) if vault_reference?(value)
      end.uniq
    end

    # Text that is about to be shown back to the operator (an error page that
    # re-renders what they typed) must never carry a private key they pasted.
    def self.scrub(text)
      text.to_s.gsub(PRIVATE_KEY_BLOCK, "[private key removed]")
    end

    def self.rejection_message(field, value, apply_mode)
      hint = "Reference one instead: #{EXAMPLE} (read from CERT_PAYMENTS_KEY on every Kong node)"
      hint += ', or in PR mode ${{ env "DECK_CERT_PAYMENTS_KEY" }}' if apply_mode != "pr"
      if deck_reference?(value)
        return "#{field}: a decK placeholder only works in PR mode -- this connection applies directly, so nothing would fill it in. #{hint}"
      end

      "#{field}: a private key can't be set from here. #{hint}"
    end
    private_class_method :rejection_message
  end
end
```

Note `hint` mentions the decK form only when the connection is not already PR mode; the message never contains the submitted value.

- [ ] **Step 4: Run the test to verify it passes**

Run: `bundle exec rspec -r "$K" spec/services/kong/certificate_key_policy_spec.rb`
Expected: PASS (all examples). If `scrub` example `expect(...).to eq("before\n[private key removed]\nafter")` fails on a trailing newline, the block regex must consume the `\n` after `-----END ... KEY-----`? It does not — adjust the *test's* `body` to end its PEM without the extra newline (`pem_key.chomp`), not the regex.

- [ ] **Step 5: Normalize line endings and commit**

```bash
sed -i 's/\r$//; s/$/\r/' app/services/kong/certificate_key_policy.rb spec/services/kong/certificate_key_policy_spec.rb
git add app/services/kong/certificate_key_policy.rb spec/services/kong/certificate_key_policy_spec.rb
git commit -m "feat(m5b): certificate key policy -- references only, never a PEM"
```

---

### Task 2: `Kong::CertificateMetadata` and the PEM fixture helper

**Files:**
- Create: `spec/support/pem_fixtures.rb`, `app/services/kong/certificate_metadata.rb`
- Test: `spec/services/kong/certificate_metadata_spec.rb`

**Interfaces:**
- Consumes: Ruby stdlib `OpenSSL`.
- Produces:
  - `PemFixtures.self_signed(cn: "spike.example.internal", days: 90, sans: [], not_before: nil) -> { cert_pem:, key_pem:, der_sha256: }` (spec helper; `require Rails.root.join("spec/support/pem_fixtures")`)
  - `Kong::CertificateMetadata.parse(pem) -> Hash` with string keys `subject issuer serial not_before not_after fingerprint_sha256 sans` (times ISO-8601 UTC strings), or `{ "parse_error" => "<reason>" }`
  - `Kong::CertificateMetadata.not_after_time(metadata) -> Time | nil`

- [ ] **Step 1: Write the fixture helper**

Create `spec/support/pem_fixtures.rb`:

```ruby
require "openssl"

# Real, throwaway certificates for specs -- generated, never checked in, and
# never sent anywhere. `days` may be negative to make an already-expired one.
module PemFixtures
  def self.self_signed(cn: "spike.example.internal", days: 90, sans: [], not_before: nil)
    key = OpenSSL::PKey::RSA.new(2048)
    cert = OpenSSL::X509::Certificate.new
    cert.version = 2
    cert.serial = SecureRandom.random_number(2**64)
    cert.subject = cert.issuer = OpenSSL::X509::Name.parse("/CN=#{cn}/O=Spec")
    cert.public_key = key.public_key
    cert.not_before = not_before || (days.negative? ? Time.now.utc + (days * 86_400) - 86_400 : Time.now.utc - 60)
    cert.not_after = Time.now.utc + (days * 86_400)

    if sans.any?
      ef = OpenSSL::X509::ExtensionFactory.new(cert, cert)
      cert.add_extension(ef.create_extension("subjectAltName", sans.map { |s| "DNS:#{s}" }.join(","), false))
    end

    cert.sign(key, OpenSSL::Digest.new("SHA256"))
    { cert_pem: cert.to_pem, key_pem: key.to_pem, der_sha256: OpenSSL::Digest::SHA256.hexdigest(cert.to_der) }
  end
end
```

- [ ] **Step 2: Write the failing test**

Create `spec/services/kong/certificate_metadata_spec.rb`:

```ruby
require "rails_helper"
require Rails.root.join("spec/support/pem_fixtures")

RSpec.describe Kong::CertificateMetadata do
  describe ".parse" do
    it "extracts the fields the read-model and dashboard need" do
      fixture = PemFixtures.self_signed(cn: "pay.example.internal", days: 90, sans: %w[pay.example.internal api.example.internal])

      meta = described_class.parse(fixture[:cert_pem])

      expect(meta["subject"]).to include("CN=pay.example.internal")
      expect(meta["issuer"]).to include("CN=pay.example.internal") # self-signed
      expect(meta["fingerprint_sha256"]).to eq(fixture[:der_sha256])
      expect(meta["fingerprint_sha256"]).to match(/\A\h{64}\z/)
      expect(meta["sans"]).to eq(%w[DNS:pay.example.internal DNS:api.example.internal])
      expect(meta["serial"]).to be_present
      expect(Time.iso8601(meta["not_after"])).to be_within(5.seconds).of(90.days.from_now)
      expect(Time.iso8601(meta["not_before"])).to be < Time.current
      expect(meta).not_to have_key("parse_error")
    end

    it "has no SANs when the certificate carries none" do
      expect(described_class.parse(PemFixtures.self_signed[:cert_pem])["sans"]).to eq([])
    end

    it "parses an already-expired certificate" do
      meta = described_class.parse(PemFixtures.self_signed(days: -10)[:cert_pem])

      expect(Time.iso8601(meta["not_after"])).to be < Time.current
    end

    it "accepts the CRLF line endings Kong returns" do
      pem = PemFixtures.self_signed[:cert_pem].gsub("\n", "\r\n")

      expect(described_class.parse(pem)).to have_key("fingerprint_sha256")
    end

    it "reports a parse_error instead of raising, for garbage, blank and nil" do
      ["not a certificate", "", nil, "-----BEGIN CERTIFICATE-----\nAAAA\n-----END CERTIFICATE-----"].each do |bad|
        meta = described_class.parse(bad)
        expect(meta.keys).to eq([ "parse_error" ]), "expected only parse_error for #{bad.inspect}"
        expect(meta["parse_error"]).to be_present
      end
    end

    it "never puts the offending PEM text into the parse_error" do
      meta = described_class.parse("-----BEGIN CERTIFICATE-----\nSECRETISH\n-----END CERTIFICATE-----")

      expect(meta["parse_error"]).not_to include("SECRETISH")
    end
  end

  describe ".not_after_time" do
    it "returns the expiry as a Time" do
      meta = described_class.parse(PemFixtures.self_signed(days: 30)[:cert_pem])

      expect(described_class.not_after_time(meta)).to be_within(5.seconds).of(30.days.from_now)
    end

    it "is nil when there is no not_after (a parse error)" do
      expect(described_class.not_after_time({ "parse_error" => "x" })).to be_nil
      expect(described_class.not_after_time(nil)).to be_nil
    end
  end
end
```

- [ ] **Step 3: Run the test to verify it fails**

Run: `bundle exec rspec -r "$K" spec/services/kong/certificate_metadata_spec.rb`
Expected: FAIL / `uninitialized constant Kong::CertificateMetadata`.

- [ ] **Step 4: Write the minimal implementation**

Create `app/services/kong/certificate_metadata.rb`:

```ruby
require "openssl"

module Kong
  # Parses a certificate PEM into the metadata the read-model caches --
  # docs/DESIGN.md section 8: "แคชเฉพาะ metadata ของ cert". The PEM itself is
  # not kept. A certificate that will not parse yields { "parse_error" => ... }
  # rather than raising: one bad certificate must never fail a whole sync.
  module CertificateMetadata
    def self.parse(pem)
      return { "parse_error" => "blank" } if pem.to_s.strip.empty?

      cert = OpenSSL::X509::Certificate.new(pem)
      {
        "subject" => cert.subject.to_s(OpenSSL::X509::Name::RFC2253),
        "issuer" => cert.issuer.to_s(OpenSSL::X509::Name::RFC2253),
        "serial" => cert.serial.to_s(16),
        "not_before" => cert.not_before.utc.iso8601,
        "not_after" => cert.not_after.utc.iso8601,
        "fingerprint_sha256" => OpenSSL::Digest::SHA256.hexdigest(cert.to_der),
        "sans" => subject_alt_names(cert)
      }
    rescue OpenSSL::X509::CertificateError, TypeError, ArgumentError => e
      # The class name only -- an OpenSSL message can quote the input.
      { "parse_error" => e.class.name }
    end

    def self.not_after_time(metadata)
      value = metadata && metadata["not_after"]
      value && Time.iso8601(value)
    end

    def self.subject_alt_names(cert)
      extension = cert.extensions.find { |e| e.oid == "subjectAltName" }
      extension ? extension.value.split(/,\s*/) : []
    end
    private_class_method :subject_alt_names
  end
end
```

- [ ] **Step 5: Run the test to verify it passes**

Run: `bundle exec rspec -r "$K" spec/services/kong/certificate_metadata_spec.rb`
Expected: PASS. If `subject`/`issuer` fail the `include("CN=...")` check, RFC2253 output is `CN=pay.example.internal,O=Spec` — the assertion already matches that; if a different format appears adjust the implementation, not the assertion.

- [ ] **Step 6: Normalize line endings and commit**

```bash
sed -i 's/\r$//; s/$/\r/' spec/support/pem_fixtures.rb app/services/kong/certificate_metadata.rb spec/services/kong/certificate_metadata_spec.rb
git add spec/support/pem_fixtures.rb app/services/kong/certificate_metadata.rb spec/services/kong/certificate_metadata_spec.rb
git commit -m "feat(m5b): parse certificate metadata from a PEM"
```

---

### Task 3: Redactor passthrough and log hygiene

**Files:**
- Modify: `app/services/kong/redactor.rb`, `config/initializers/filter_parameter_logging.rb`
- Test: `spec/services/kong/redactor_spec.rb` (extend), `spec/requests/log_filtering_spec.rb` (create)

**Interfaces:**
- Consumes: `Kong::CertificateKeyPolicy.reference?(value)` (Task 1).
- Produces: `Kong::Redactor.call("certificate", data)` leaves a `key`/`key_alt` reference readable and redacts anything else, including `key_alt`; `Kong::Redactor.prune_sensitive("certificate", data)` **keeps** `key`/`key_alt` untouched (the planner's policy decides); every other type behaves exactly as before.

- [ ] **Step 1: Write the failing tests**

Append inside the top-level `RSpec.describe Kong::Redactor do` block of `spec/services/kong/redactor_spec.rb` (read the file first to place it before the final `end`):

```ruby
  describe "certificate key references (M5b)" do
    it "lets a vault reference through, since it is a pointer and not a secret" do
      result = described_class.call("certificate", { "key" => "{vault://env/cert-a-key}", "cert" => "PEM" })

      expect(result[:data]["key"]).to eq("{vault://env/cert-a-key}")
    end

    it "lets a decK placeholder through too" do
      result = described_class.call("certificate", { "key" => '${{ env "DECK_A" }}' })

      expect(result[:data]["key"]).to eq('${{ env "DECK_A" }}')
    end

    it "still redacts a plaintext key, in key and in key_alt" do
      pem = "-----BEGIN PRIVATE KEY-----\nAAAA\n-----END PRIVATE KEY-----"
      result = described_class.call("certificate", { "key" => pem, "key_alt" => pem })

      expect(result[:data]).to eq({ "key" => "[REDACTED]", "key_alt" => "[REDACTED]" })
    end

    it "passes a reference in key_alt through as well" do
      result = described_class.call("certificate", { "key_alt" => "{vault://env/cert-b-key}" })

      expect(result[:data]["key_alt"]).to eq("{vault://env/cert-b-key}")
    end

    it "does not extend the passthrough to any other entity type" do
      result = described_class.call("keyauth_credential", { "key" => "{vault://env/looks-like-a-ref}" })

      expect(result[:data]["key"]).to eq("[REDACTED]")
    end

    it "keeps certificate keys out of prune_sensitive so the planner's policy can reject a PEM loudly" do
      data = { "key" => "-----BEGIN PRIVATE KEY-----\nA\n-----END PRIVATE KEY-----", "key_alt" => "{vault://env/x}", "tags" => [ "t" ] }

      expect(described_class.prune_sensitive("certificate", data)).to eq(data)
    end

    it "still prunes a credential secret from a form exactly as before" do
      expect(described_class.prune_sensitive("keyauth_credential", { "key" => "s", "tags" => [] })).to eq({ "tags" => [] })
    end

    it "digests the redacted form, so a reference change changes the digest" do
      a = described_class.call("certificate", { "key" => "{vault://env/a}" })
      b = described_class.call("certificate", { "key" => "{vault://env/b}" })

      expect(a[:digest]).not_to eq(b[:digest])
    end
  end
```

Create `spec/requests/log_filtering_spec.rb`:

```ruby
require "rails_helper"

# A private key pasted into a certificate form or sent as an API attribute
# must never reach the Rails log. Parameter names in play: the web form's
# `payload_json`, and the API's nested `attributes[key]` / `attributes[key_alt]`.
RSpec.describe "Parameter log filtering" do
  let(:filter) { ActiveSupport::ParameterFilter.new(Rails.application.config.filter_parameters) }

  it "filters the JSON editor's payload" do
    expect(filter.filter("payload_json" => "{\"key\":\"-----BEGIN PRIVATE KEY-----\"}")["payload_json"]).to eq("[FILTERED]")
  end

  it "filters a nested API key and key_alt" do
    filtered = filter.filter("attributes" => { "key" => "PEM", "key_alt" => "PEM", "tags" => [ "ok" ] })

    expect(filtered["attributes"]).to eq({ "key" => "[FILTERED]", "key_alt" => "[FILTERED]", "tags" => [ "ok" ] })
  end

  it "does not blank unrelated params such as the type or connection" do
    expect(filter.filter("type" => "certificate", "connection" => "dev")).to eq({ "type" => "certificate", "connection" => "dev" })
  end
end
```

- [ ] **Step 2: Run to verify they fail**

Run: `bundle exec rspec -r "$K" spec/services/kong/redactor_spec.rb spec/requests/log_filtering_spec.rb`
Expected: the new redactor examples FAIL (key passes as `[REDACTED]`; `key_alt` not redacted; prune drops key) and the two filtering examples for `payload_json` / nested key FAIL. Existing examples still pass.

- [ ] **Step 3: Implement the redactor change**

In `app/services/kong/redactor.rb` make these edits (use the Edit tool; the file is CRLF).

Replace the certificate entry in `SENSITIVE_FIELDS_BY_ENTITY`:

```ruby
      "certificate" => %w[key key_alt],
```

Add this constant and class method after `sensitive_key?`:

```ruby
    # M5b: on a certificate a `key` that is a vault/decK reference is a
    # pointer, not a secret, and operators need to see which variable it
    # names. Deliberately narrow -- certificate only, key/key_alt only -- so
    # a credential's `key` (or anything else) is never let through.
    REFERENCE_PASSTHROUGH_FIELDS = %w[key key_alt].freeze

    def self.reference_passthrough?(entity_type, key, value)
      entity_type.to_s == "certificate" &&
        REFERENCE_PASSTHROUGH_FIELDS.include?(key.to_s) &&
        Kong::CertificateKeyPolicy.reference?(value)
    end
```

Change `prune_sensitive` so a certificate's key fields are left for the planner's policy to judge (silently dropping a pasted PEM would leave the operator thinking a key was set):

```ruby
    def self.prune_sensitive(entity_type, data)
      deep_prune(data) do |key, _value|
        sensitive_key?(entity_type, key) && !policy_owned?(entity_type, key)
      end
    end

    # Certificate key/key_alt are judged by Kong::CertificateKeyPolicy, which
    # raises on anything but a reference, so they must reach it unpruned.
    def self.policy_owned?(entity_type, key)
      entity_type.to_s == "certificate" && REFERENCE_PASSTHROUGH_FIELDS.include?(key.to_s)
    end
    private_class_method :policy_owned?
```

Change `deep_redact` and `redact_key?` (instance methods) to take the value:

```ruby
    def deep_redact(value)
      case value
      when Hash
        value.each_with_object({}) do |(key, v), acc|
          acc[key] = redact?(key, v) ? MARK : deep_redact(v)
        end
      when Array
        value.map { |v| deep_redact(v) }
      else
        value
      end
    end

    def redact?(key, value)
      self.class.sensitive_key?(@entity_type, key) && !self.class.reference_passthrough?(@entity_type, key, value)
    end
```

Delete the now-unused `redact_key?` method.

- [ ] **Step 4: Implement the log filtering**

In `config/initializers/filter_parameter_logging.rb` extend the list:

```ruby
Rails.application.config.filter_parameters += [
  :passw, :email, :secret, :token, :_key, :crypt, :salt, :certificate, :otp, :ssn, :cvv, :cvc,
  # M5b: a private key pasted into a certificate form arrives inside the JSON
  # editor's payload; the API sends it as attributes[key] / attributes[key_alt].
  :payload_json, /(\A|\.)key(_alt)?\z/
]
```

- [ ] **Step 5: Run to verify they pass, then the wider suite**

Run: `bundle exec rspec -r "$K" spec/services/kong/redactor_spec.rb spec/requests/log_filtering_spec.rb`
Expected: PASS.
Then `bundle exec rspec -r "$K"` — expected **no regressions** (baseline 328 + the new examples, 0 failures). If a request spec asserted a log line containing `payload_json`, update it to expect `[FILTERED]`.

- [ ] **Step 6: Normalize line endings and commit**

```bash
sed -i 's/\r$//; s/$/\r/' spec/requests/log_filtering_spec.rb
git add app/services/kong/redactor.rb config/initializers/filter_parameter_logging.rb spec/services/kong/redactor_spec.rb spec/requests/log_filtering_spec.rb
git commit -m "feat(m5b): pass key references through the redactor, keep PEMs out of logs"
```

### Task 4: Register the three types, expiry status, and certificate labels

**Files:**
- Modify: `app/services/kong/entity_types.rb`, `app/models/kong_entity.rb`
- Test: `spec/services/kong/entity_types_spec.rb` (extend), `spec/models/kong_entity_spec.rb` (create), `spec/models/change_plan_spec.rb` (extend)

**Interfaces:**
- Consumes: `Kong::EntityTypes::Definition` (M5a: members `list_path parent_type create_path_proc nested_collection_proc schema_name`).
- Produces:
  - `Definition#parent_in_body` (new struct member, default nil) and `Definition#requires_parent?` (`nested? || parent_in_body`).
  - `Kong::EntityTypes.fetch("certificate" | "sni" | "ca_certificate")`; `sni` has `parent_type: "certificate"`, `parent_in_body: true`.
  - `Kong::EntityTypes.label(*docs)` also returns a certificate's first SNI (sorted).
  - `KongEntity#expiry_status(now = Time.current) -> "expired" | "critical" | "warning" | "ok" | nil`, constants `KongEntity::EXPIRY_CRITICAL = 7.days`, `EXPIRY_WARNING = 30.days`, scope `KongEntity.expiring_within(days)`.

- [ ] **Step 1: Write the failing tests**

Append inside `RSpec.describe Kong::EntityTypes do` in `spec/services/kong/entity_types_spec.rb` (before the final `end`; the file is CRLF, use the Edit tool anchored on the last `describe`):

```ruby
  describe "certificate types (M5b)" do
    it "registers certificate, sni and ca_certificate as flat collections with schema names" do
      { "certificate" => [ "/certificates", "certificates" ],
        "sni" => [ "/snis", "snis" ],
        "ca_certificate" => [ "/ca_certificates", "ca_certificates" ] }.each do |type, (path, schema)|
        definition = described_class.fetch(type)
        expect(definition).not_to be_nested
        expect(definition.collection_path).to eq(path)
        expect(definition.member_path("abc")).to eq("#{path}/abc")
        expect(definition.schema_name).to eq(schema)
      end
    end

    it "makes an sni a flat child whose create body carries its certificate" do
      sni = described_class.fetch("sni")

      expect(sni.parent_type).to eq("certificate")
      expect(sni.parent_in_body).to be(true)
      expect(sni.requires_parent?).to be(true)
      expect(sni.create_path).to eq("/snis")
    end

    it "does not make other types require a parent by accident" do
      expect(described_class.fetch("certificate").requires_parent?).to be(false)
      expect(described_class.fetch("route").requires_parent?).to be(false)
      expect(described_class.fetch("target").requires_parent?).to be(true) # nested
    end

    it "labels a certificate by its first SNI in sorted order, since Kong gives it no name" do
      expect(described_class.label({ "snis" => %w[b.example a.example] })).to eq("a.example")
      expect(described_class.label({ "snis" => [] })).to be_nil
    end
  end
```

Create `spec/models/kong_entity_spec.rb`:

```ruby
require "rails_helper"

RSpec.describe KongEntity do
  describe "#expiry_status" do
    let(:now) { Time.zone.local(2026, 9, 21, 12, 0, 0) }

    def status(not_after)
      build(:kong_entity, not_after: not_after).expiry_status(now)
    end

    it "is nil when there is no not_after (every non-certificate entity)" do
      expect(status(nil)).to be_nil
    end

    it "is expired once not_after has passed, including the instant itself" do
      expect(status(now - 1.second)).to eq("expired")
      expect(status(now)).to eq("expired")
    end

    it "is critical within 7 days, boundary inclusive" do
      expect(status(now + 1.second)).to eq("critical")
      expect(status(now + 7.days)).to eq("critical")
    end

    it "is warning past 7 days and up to 30, boundary inclusive" do
      expect(status(now + 7.days + 1.second)).to eq("warning")
      expect(status(now + 30.days)).to eq("warning")
    end

    it "is ok beyond 30 days" do
      expect(status(now + 30.days + 1.second)).to eq("ok")
    end
  end

  describe ".expiring_within" do
    it "returns active-or-not rows expiring inside the window, expired ones included, ordered by the caller" do
      connection = create(:kong_connection)
      soon = create(:kong_entity, kong_connection: connection, entity_type: "certificate", not_after: 3.days.from_now)
      gone = create(:kong_entity, kong_connection: connection, entity_type: "certificate", not_after: 2.days.ago)
      create(:kong_entity, kong_connection: connection, entity_type: "certificate", not_after: 90.days.from_now)
      create(:kong_entity, kong_connection: connection, entity_type: "service", not_after: nil)

      expect(described_class.expiring_within(30)).to contain_exactly(soon, gone)
    end
  end
end
```

Append inside `RSpec.describe ChangePlan do` in `spec/models/change_plan_spec.rb`:

```ruby
  describe "#entity_label for a certificate" do
    it "is the first SNI in sorted order, from the create body" do
      plan = build(:change_plan, entity_type: "certificate", operation: "create", before: {},
        after: { "snis" => %w[b.example a.example], "key" => "{vault://env/x}" })

      expect(plan.entity_label).to eq("a.example")
    end
  end
```

- [ ] **Step 2: Run to verify they fail**

Run: `bundle exec rspec -r "$K" spec/services/kong/entity_types_spec.rb spec/models/kong_entity_spec.rb spec/models/change_plan_spec.rb`
Expected: FAIL — `unknown entity_type "certificate"`, `undefined method 'expiry_status'`, `undefined method 'requires_parent?'`.

- [ ] **Step 3: Implement the registry changes**

In `app/services/kong/entity_types.rb`:

1. Add the struct member — change the `Definition = Struct.new(` line's member list to end with `:schema_name, :parent_in_body,`:

```ruby
    Definition = Struct.new(:list_path, :parent_type, :create_path_proc, :nested_collection_proc, :schema_name,
                             :parent_in_body, keyword_init: true) do
```

2. Add inside that struct block, next to `nested?`:

```ruby
      # A flat child (sni) still needs its parent: the create body must carry
      # `certificate: {id}`. `nested?` types (target) need it for the path.
      def requires_parent?
        nested? || parent_in_body.present?
      end
```

3. In `DEFINITIONS`, the `"target"` entry currently ends with a bare `)`. Make it `),` and add these entries after it (the hash's closing `}.freeze` follows the last one, with no trailing comma):

```ruby
      # M5b. All three are flat top-level collections in Kong 3.7 -- unlike a
      # target, an SNI is listable and addressable without its certificate.
      "certificate" => Definition.new(list_path: "/certificates", parent_type: nil, schema_name: "certificates"),
      "sni" => Definition.new(list_path: "/snis", parent_type: "certificate", schema_name: "snis", parent_in_body: true),
      "ca_certificate" => Definition.new(list_path: "/ca_certificates", parent_type: nil, schema_name: "ca_certificates")
```

4. Replace `self.label`:

```ruby
    def self.label(*documents)
      documents.each do |doc|
        label = doc && (doc["name"].presence || doc["target"].presence || Array(doc["snis"]).min.presence)
        return label if label
      end
      nil
    end
```

- [ ] **Step 4: Implement `KongEntity` expiry**

In `app/models/kong_entity.rb`, add after the existing scopes (and fix the stale header comment while there — it still says "currently: services only"):

```ruby
  # docs/DESIGN.md section 8 / M5b spec section 5. Kong::CertificateMetadata
  # fills `not_after` at sync time; nothing here reads a certificate.
  EXPIRY_CRITICAL = 7.days
  EXPIRY_WARNING = 30.days

  scope :expiring_within, ->(days) { where.not(not_after: nil).where(not_after: ..days.to_i.days.from_now) }

  def expiry_status(now = Time.current)
    return nil if not_after.nil?
    return "expired" if not_after <= now
    return "critical" if not_after <= now + EXPIRY_CRITICAL
    return "warning" if not_after <= now + EXPIRY_WARNING

    "ok"
  end
```

`ChangePlan#entity_label` already delegates to `Kong::EntityTypes.label(before, after)` (M5a), so it needs no change.

- [ ] **Step 5: Run to verify they pass**

Run: `bundle exec rspec -r "$K" spec/services/kong/entity_types_spec.rb spec/models`
Expected: PASS.

- [ ] **Step 6: Normalize line endings and commit**

```bash
sed -i 's/\r$//; s/$/\r/' spec/models/kong_entity_spec.rb
git add app/services/kong/entity_types.rb app/models/kong_entity.rb spec/services/kong/entity_types_spec.rb spec/models
git commit -m "feat(m5b): register certificate, sni, ca_certificate; expiry status"
```

---

### Task 5: Sync certificates, SNIs and CA certificates

**Files:**
- Modify: `app/services/kong/entity_sync.rb`, `spec/services/kong/entity_sync_spec.rb`, `spec/requests/entities_spec.rb`
- Test: `spec/services/kong/entity_sync_spec.rb`

**Interfaces:**
- Consumes: `Kong::CertificateMetadata.parse` / `.not_after_time` (Task 2), `Kong::EntityTypes` new types (Task 4), `Kong::Redactor` (Task 3).
- Produces: `KongEntity` rows for the three types: `name`, `logical_key`, `parent_type`/`parent_kong_id` (sni → certificate), `not_after` (certificate, ca_certificate), `data` with `_metadata` and **no** `cert`/`cert_alt`; `Kong::EntitySync::TYPES_IN_SYNC_ORDER` ends `... upstream target certificate sni ca_certificate`.

- [ ] **Step 1: Write the failing tests**

Add `require Rails.root.join("spec/support/pem_fixtures")` under `require "rails_helper"` at the top of `spec/services/kong/entity_sync_spec.rb`, then insert this block before the existing `describe ".sync_connection" do` (Edit tool, anchor on that line):

```ruby
  describe "certificates, SNIs and CA certificates (M5b)" do
    let(:cert_id) { "dddddddd-0000-0000-0000-00000000000d" }
    let(:sni_id) { "eeeeeeee-0000-0000-0000-00000000000e" }
    let(:ca_id) { "ffffffff-0000-0000-0000-00000000000f" }
    let(:fixture) { PemFixtures.self_signed(cn: "pay.example.internal", days: 45, sans: %w[pay.example.internal]) }
    let(:cert_sync) { described_class.new(connection: connection, client: client, entity_type: "certificate") }

    def stub_list(path, data)
      stub_request(:get, "https://kong-admin.internal/#{path}").with(query: { size: "100" })
        .to_return(status: 200, body: { data: data, offset: nil }.to_json)
    end

    def kong_cert(overrides = {})
      { id: cert_id, cert: fixture[:cert_pem], key: "{vault://env/cert-pay-key}", snis: %w[pay.example.internal api.example.internal],
        tags: [ "core" ], created_at: 1_700_000_000, updated_at: 1_700_000_100 }.merge(overrides)
    end

    it "names a certificate by its first SNI (sorted) and keys it by the sorted SNI list" do
      stub_list("certificates", [ kong_cert(snis: %w[b.example a.example]) ])

      cert_sync.call

      row = KongEntity.find_by(kong_id: cert_id)
      expect(row.entity_type).to eq("certificate")
      expect(row.name).to eq("a.example")
      expect(row.logical_key).to eq("a.example,b.example")
      expect(row.parent_type).to be_nil
    end

    it "falls back to the fingerprint's first 12 characters when the certificate has no SNI" do
      stub_list("certificates", [ kong_cert(snis: []) ])

      cert_sync.call

      row = KongEntity.find_by(kong_id: cert_id)
      expect(row.name).to eq(fixture[:der_sha256][0..11])
      expect(row.logical_key).to eq(fixture[:der_sha256])
    end

    it "caches metadata and the not_after column, and never the PEM" do
      stub_list("certificates", [ kong_cert(cert_alt: fixture[:cert_pem]) ])

      cert_sync.call

      row = KongEntity.find_by(kong_id: cert_id)
      expect(row.not_after).to be_within(5.seconds).of(45.days.from_now)
      expect(row.data).not_to have_key("cert")
      expect(row.data).not_to have_key("cert_alt")
      expect(row.data["_metadata"]).to include("fingerprint_sha256" => fixture[:der_sha256], "sans" => [ "DNS:pay.example.internal" ])
      expect(row.data.to_json).not_to include("BEGIN CERTIFICATE")
      expect(row.expiry_status).to eq("warning")
    end

    it "keeps a vault reference readable but redacts a plaintext key that Kong hands back" do
      stub_list("certificates", [
        kong_cert,
        kong_cert(id: "99999999-0000-0000-0000-000000000009", snis: [ "legacy.example" ], key: fixture[:key_pem])
      ])

      cert_sync.call

      expect(KongEntity.find_by(kong_id: cert_id).data["key"]).to eq("{vault://env/cert-pay-key}")
      legacy = KongEntity.find_by(kong_id: "99999999-0000-0000-0000-000000000009")
      expect(legacy.data["key"]).to eq("[REDACTED]")
      expect(legacy.data.to_json).not_to include("PRIVATE KEY")
    end

    it "never fails a sync over a certificate whose PEM will not parse" do
      stub_list("certificates", [ kong_cert(cert: "garbage"), kong_cert(id: "88888888-0000-0000-0000-000000000008", snis: [ "ok.example" ]) ])

      result = cert_sync.call

      expect(result.synced_count).to eq(2)
      broken = KongEntity.find_by(kong_id: cert_id)
      expect(broken.not_after).to be_nil
      expect(broken.expiry_status).to be_nil
      expect(broken.data["_metadata"].keys).to eq([ "parse_error" ])
      expect(broken.name).to eq("api.example.internal") # named from the SNI list, which needs no PEM
    end

    it "re-syncing updates not_after and the digest when the certificate is replaced" do
      stub_list("certificates", [ kong_cert ])
      cert_sync.call
      first = KongEntity.find_by(kong_id: cert_id)

      renewed = PemFixtures.self_signed(cn: "pay.example.internal", days: 365)
      stub_list("certificates", [ kong_cert(cert: renewed[:cert_pem]) ])
      cert_sync.call

      second = KongEntity.find_by(kong_id: cert_id)
      expect(second.not_after).to be > first.not_after + 300.days
      expect(second.digest).not_to eq(first.digest)
      expect(KongEntity.where(kong_id: cert_id).count).to eq(1)
    end

    it "syncs an SNI by hostname, parented to its certificate" do
      stub_list("snis", [ { id: sni_id, name: "pay.example.internal", certificate: { id: cert_id }, tags: [] } ])

      described_class.new(connection: connection, client: client, entity_type: "sni").call

      row = KongEntity.find_by(kong_id: sni_id)
      expect(row.name).to eq("pay.example.internal")
      expect(row.logical_key).to eq("pay.example.internal")
      expect(row.parent_type).to eq("certificate")
      expect(row.parent_kong_id).to eq(cert_id)
      expect(row.not_after).to be_nil
    end

    it "syncs a CA certificate by its cert_digest, with metadata and expiry" do
      digest = "9852b7219ac320e83b0cddcc132766331667e7b290477751e5397eeb5aef4dd5"
      stub_list("ca_certificates", [ { id: ca_id, cert: fixture[:cert_pem], cert_digest: digest, tags: [] } ])

      described_class.new(connection: connection, client: client, entity_type: "ca_certificate").call

      row = KongEntity.find_by(kong_id: ca_id)
      expect(row.name).to eq(digest[0..11])
      expect(row.logical_key).to eq(digest)
      expect(row.not_after).to be_within(5.seconds).of(45.days.from_now)
      expect(row.data).not_to have_key("cert")
    end

    it "soft-deletes a certificate that is no longer in Kong" do
      gone = create(:kong_entity, kong_connection: connection, entity_type: "certificate",
        kong_id: "77777777-0000-0000-0000-000000000007", name: "old.example")
      stub_list("certificates", [ kong_cert ])

      result = cert_sync.call

      expect(result.removed_count).to eq(1)
      expect(gone.reload.deleted_at).to be_present
    end

    it "orders certificates before their SNIs in the connection sync" do
      order = described_class::TYPES_IN_SYNC_ORDER

      expect(order.index("certificate")).to be < order.index("sni")
      expect(order.last(3)).to eq(%w[certificate sni ca_certificate])
    end

    it "re-syncs a single certificate through sync_one (used after an SNI write)" do
      stub_request(:get, "https://kong-admin.internal/certificates/#{cert_id}")
        .to_return(status: 200, body: kong_cert(snis: [ "new.example" ]).to_json)

      entity = described_class.sync_one(connection: connection, client: client, entity_type: "certificate", kong_id: cert_id)

      expect(entity.name).to eq("new.example")
    end
  end
```

Also update the two existing `.sync_connection` examples in the same file: add `certificates snis ca_certificates` to their path arrays (`%w[services consumers routes key-auths basic-auths plugins upstreams]` becomes `%w[services consumers routes key-auths basic-auths plugins upstreams certificates snis ca_certificates]`, in **both** the stub loop and the assertion loop of the first example, and in the stub loop of the second example). Without this those examples fail with `Unregistered request`.

In `spec/requests/entities_spec.rb`, the sync examples stub each collection path explicitly. Add the three new paths everywhere `upstreams` is stubbed for a sync: in `"syncs from Kong on demand"` add three more `stub_request(:get, "https://kong-admin.test/<path>").with(query: { size: "100" }).to_return(status: 200, body: { data: [], offset: nil }.to_json)` blocks for `certificates`, `snis`, `ca_certificates`; in the two `%w[services consumers routes key-auths basic-auths plugins upstreams].each` loops append `certificates snis ca_certificates`; and in the M5a example `"syncs upstreams and their targets from the Sync now button"` add the three paths to its `%w[services consumers key-auths basic-auths plugins]` loop.

- [ ] **Step 2: Run to verify they fail**

Run: `bundle exec rspec -r "$K" spec/services/kong/entity_sync_spec.rb`
Expected: the new examples FAIL (`no identity rule for entity_type "certificate"`), the updated `.sync_connection` examples FAIL (they now stub paths the sync does not request — `have_requested` assertion fails).

- [ ] **Step 3: Implement**

In `app/services/kong/entity_sync.rb`:

1. Order constant:

```ruby
    TYPES_IN_SYNC_ORDER = %w[service consumer route keyauth_credential basicauth_credential plugin upstream target
                             certificate sni ca_certificate].freeze
    CERTIFICATE_TYPES = %w[certificate ca_certificate].freeze
```

2. Replace the whole `upsert` method with this (the new lines are `metadata`, `data`, the `identify(raw, metadata)` argument, `not_after:` and `data: data`; everything else is the existing code):

```ruby
    def upsert(raw)
      redacted = Kong::Redactor.call(@entity_type, raw)
      metadata = certificate_metadata(raw)
      data = metadata ? cached_certificate_data(redacted[:data], metadata) : redacted[:data]
      now = Time.current
      identity = identify(raw, metadata)

      entity = KongEntity.find_or_initialize_by(
        kong_connection: @connection, entity_type: @entity_type, kong_id: raw.fetch("id")
      )
      entity.first_seen_at ||= now
      entity.assign_attributes(
        name: identity[:name],
        logical_key: identity[:logical_key],
        parent_type: identity[:parent_type],
        parent_kong_id: identity[:parent_kong_id],
        tags: Array(raw["tags"]),
        kong_created_at: from_kong_timestamp(raw["created_at"]),
        kong_updated_at: from_kong_timestamp(raw["updated_at"]),
        enabled: raw["enabled"],
        is_admin_path: @connection.admin_path?(raw.fetch("id")),
        not_after: Kong::CertificateMetadata.not_after_time(metadata),
        data: data,
        digest: redacted[:digest],
        synced_at: now,
        deleted_at: nil
      )
      entity.save!
      entity
    end
```

`digest` stays the redactor's digest of the full redacted document (PEM included), so replacing a certificate changes it even though the PEM is no longer stored.

3. Change `identify(raw)` to `identify(raw, metadata = nil)` and add branches before `else`:

```ruby
      when "certificate"
        identify_certificate(raw, metadata)
      when "sni"
        { name: raw["name"], logical_key: raw["name"], parent_type: "certificate", parent_kong_id: raw.dig("certificate", "id") }
      when "ca_certificate"
        digest = raw["cert_digest"] || metadata&.dig("fingerprint_sha256") || raw.fetch("id")
        { name: digest[0..11], logical_key: digest, parent_type: nil, parent_kong_id: nil }
```

4. Add private helpers:

```ruby
    def certificate_metadata(raw)
      Kong::CertificateMetadata.parse(raw["cert"]) if CERTIFICATE_TYPES.include?(@entity_type)
    end

    # docs/DESIGN.md section 8: cache metadata, not the certificate body.
    def cached_certificate_data(data, metadata)
      data.except("cert", "cert_alt").merge("_metadata" => metadata)
    end

    # DESIGN section 7: first SNI (sorted), else fingerprint[0..11]; the
    # logical_key is the sorted SNI set, else the whole fingerprint.
    def identify_certificate(raw, metadata)
      snis = Array(raw["snis"]).sort
      fingerprint = metadata&.dig("fingerprint_sha256")
      fallback = fingerprint ? fingerprint[0..11] : raw.fetch("id")[0..7]
      key = snis.any? ? snis.join(",") : (fingerprint || raw.fetch("id"))
      { name: snis.first || fallback, logical_key: key, parent_type: nil, parent_kong_id: nil }
    end
```

Where the existing `identify` is called (`identity = identify(raw)`), pass `metadata`. `parent_name_map` already keys off `@definition.parent_type`, which is harmless for `sni`.

- [ ] **Step 4: Run to verify they pass**

Run: `bundle exec rspec -r "$K" spec/services/kong/entity_sync_spec.rb spec/requests/entities_spec.rb`
Expected: PASS. The "never fails a sync over a PEM that will not parse" example uses loose `.or` matchers on `name` and `_metadata` on purpose: with `snis` present the name comes from the SNI list regardless of PEM validity.

- [ ] **Step 5: Commit**

```bash
git add app/services/kong/entity_sync.rb spec/services/kong/entity_sync_spec.rb spec/requests/entities_spec.rb
git commit -m "feat(m5b): sync certificates, SNIs and CA certificates with cached metadata"
```

---

### Task 6: Planner — enforce the key policy, parent handling for SNIs, no schema POST in PR mode

**Files:**
- Modify: `app/services/kong/change_planner.rb`
- Test: `spec/services/kong/change_planner_spec.rb` (extend)

**Interfaces:**
- Consumes: `Kong::CertificateKeyPolicy.check!` (Task 1), `Definition#requires_parent?`/`parent_in_body` (Task 4).
- Produces: `ChangePlanner` raises `Kong::CertificateKeyPolicy::Rejected` (a 422-class `InvalidChange`) before any Kong call for a bad `key`/`key_alt`; a certificate create requires a key; an SNI create requires `parent_kong_id` and its plan `after` carries `"certificate" => {"id" => parent}`; schema validation posts that parent reference for any `requires_parent?` type; **no `POST /schemas/*/validate` is made when the connection's `apply_mode` is `pr`** (a read-only route answers a POST with Kong's router 404; `deck gateway validate` covers PR mode in CI).

- [ ] **Step 1: Write the failing tests**

Add `require Rails.root.join("spec/support/pem_fixtures")` under `require "rails_helper"` in `spec/services/kong/change_planner_spec.rb`, then insert before the final `end` (the `planner(**overrides)` helper defaults `entity_type: "service"`; override it):

```ruby
  describe "certificates and SNIs (M5b)" do
    let(:cert_id) { "dddddddd-0000-0000-0000-00000000000d" }
    let(:pem) { PemFixtures.self_signed(days: 60)[:cert_pem] }
    let(:ok) { { status: 200, body: { message: "schema validation successful" }.to_json } }
    let(:validate_certs) { "https://kong-admin.internal/schemas/certificates/validate" }
    let(:validate_snis) { "https://kong-admin.internal/schemas/snis/validate" }

    def cert_planner(**overrides)
      planner(entity_type: "certificate", **overrides)
    end

    describe "certificate key policy" do
      it "proposes a create whose key is a vault reference, validating it with Kong" do
        validate = stub_request(:post, validate_certs).to_return(ok)

        plan = cert_planner(operation: "create",
          attributes: { "cert" => pem, "key" => "{vault://env/cert-pay-key}", "snis" => [ "pay.example.internal" ] }).call

        expect(plan).to be_persisted
        expect(plan.after["key"]).to eq("{vault://env/cert-pay-key}")
        expect(validate.with(body: hash_including("key" => "{vault://env/cert-pay-key}"))).to have_been_requested
      end

      it "rejects a PEM key before any request reaches Kong, never persisting or echoing it" do
        pem_key = PemFixtures.self_signed[:key_pem]

        expect {
          cert_planner(operation: "create", attributes: { "cert" => pem, "key" => pem_key }).call
        }.to raise_error(Kong::CertificateKeyPolicy::Rejected) { |e|
          expect(e).to be_a(Kong::ChangePlanner::InvalidChange)
          expect(e.message).not_to include("PRIVATE KEY")
        }
        expect(ChangePlan.count).to eq(0)
        expect(WebMock).not_to have_requested(:any, /kong-admin/)
      end

      it "rejects a create with no key at all" do
        expect {
          cert_planner(operation: "create", attributes: { "cert" => pem }).call
        }.to raise_error(Kong::CertificateKeyPolicy::Rejected, /needs a key/)
      end

      it "rejects a decK placeholder on a direct-mode connection" do
        expect {
          cert_planner(operation: "create", attributes: { "cert" => pem, "key" => '${{ env "DECK_CERT_A" }}' }).call
        }.to raise_error(Kong::CertificateKeyPolicy::Rejected, /direct/)
      end

      it "rejects a PEM smuggled into key_alt on update, too" do
        expect {
          cert_planner(operation: "update", target_kong_id: cert_id,
            attributes: { "key_alt" => "-----BEGIN PRIVATE KEY-----\nA\n-----END PRIVATE KEY-----" }).call
        }.to raise_error(Kong::CertificateKeyPolicy::Rejected, /key_alt/)
        expect(WebMock).not_to have_requested(:any, /kong-admin/)
      end

      it "proposes a tags-only update without touching key policy, keeping the live reference readable" do
        stub_request(:get, "https://kong-admin.internal/certificates/#{cert_id}").to_return(status: 200, body: {
          id: cert_id, cert: pem, key: "{vault://env/cert-pay-key}", snis: [ "pay.example.internal" ], tags: [], updated_at: 1_700_000_000
        }.to_json)
        stub_request(:post, validate_certs).to_return(ok)

        plan = cert_planner(operation: "update", target_kong_id: cert_id, attributes: { "tags" => [ "core" ] }).call

        expect(plan.diff).to eq({ "tags" => { "from" => [], "to" => [ "core" ] } })
        expect(plan.before["key"]).to eq("{vault://env/cert-pay-key}")
      end

      it "redacts a plaintext key Kong hands back and never carries it into after" do
        stub_request(:get, "https://kong-admin.internal/certificates/#{cert_id}").to_return(status: 200, body: {
          id: cert_id, cert: pem, key: "-----BEGIN PRIVATE KEY-----\nLEGACY\n-----END PRIVATE KEY-----", snis: [], tags: [], updated_at: 1_700_000_000
        }.to_json)
        stub_request(:post, validate_certs).to_return(ok)

        plan = cert_planner(operation: "update", target_kong_id: cert_id, attributes: { "tags" => [ "x" ] }).call

        expect(plan.before["key"]).to eq("[REDACTED]")
        expect(plan.after).not_to have_key("key")
        expect(plan.to_json).not_to include("LEGACY")
      end
    end

    describe "PR-mode connections" do
      it "accepts a decK placeholder and makes no schema POST (a read-only route would 404 it)" do
        connection.update!(apply_mode: "pr", access_level: "ro")

        plan = cert_planner(operation: "create", attributes: { "cert" => pem, "key" => '${{ env "DECK_CERT_A" }}' }).call

        expect(plan.apply_mode).to eq("pr")
        expect(plan.after["key"]).to eq('${{ env "DECK_CERT_A" }}')
        expect(WebMock).not_to have_requested(:any, /kong-admin/)
      end

      it "skips the schema POST for the M5a types too -- upstreams and targets in PR mode" do
        connection.update!(apply_mode: "pr", access_level: "ro")

        plan = planner(entity_type: "upstream", operation: "create", attributes: { "name" => "orders" }).call

        expect(plan).to be_persisted
        expect(WebMock).not_to have_requested(:post, /schemas/)
      end
    end

    describe "sni" do
      def sni_planner(**overrides)
        planner(entity_type: "sni", **overrides)
      end

      it "requires a certificate on create" do
        expect {
          sni_planner(operation: "create", attributes: { "name" => "pay.example.internal" }).call
        }.to raise_error(Kong::ChangePlanner::MissingParent, /certificate/)
        expect(ChangePlan.count).to eq(0)
      end

      it "carries the certificate reference in the create body, and validates with it" do
        validate = stub_request(:post, validate_snis).to_return(ok)

        plan = sni_planner(operation: "create", parent_kong_id: cert_id, attributes: { "name" => "pay.example.internal" }).call

        expect(plan.after).to eq({ "name" => "pay.example.internal", "certificate" => { "id" => cert_id } })
        expect(plan.parent_kong_id).to eq(cert_id)
        expect(validate.with(body: { "name" => "pay.example.internal", "certificate" => { "id" => cert_id } })).to have_been_requested
      end

      it "plans an SNI delete without needing the parent for any path, but records it from the read-model when known" do
        sni_id = "eeeeeeee-0000-0000-0000-00000000000e"
        create(:kong_entity, kong_connection: connection, entity_type: "sni", kong_id: sni_id, name: "pay.example.internal",
          parent_type: "certificate", parent_kong_id: cert_id)
        stub_request(:get, "https://kong-admin.internal/snis/#{sni_id}")
          .to_return(status: 200, body: { id: sni_id, name: "pay.example.internal", certificate: { id: cert_id }, updated_at: 1_700_000_000 }.to_json)

        plan = sni_planner(operation: "delete", target_kong_id: sni_id).call

        expect(plan.parent_kong_id).to eq(cert_id)
      end

      it "still plans an SNI delete when the read-model has never seen it (parent unknown is fine for a flat child)" do
        sni_id = "eeeeeeee-0000-0000-0000-00000000000e"
        stub_request(:get, "https://kong-admin.internal/snis/#{sni_id}")
          .to_return(status: 200, body: { id: sni_id, name: "x.example", certificate: { id: cert_id }, updated_at: 1_700_000_000 }.to_json)

        plan = sni_planner(operation: "delete", target_kong_id: sni_id).call

        expect(plan).to be_persisted
        expect(plan.parent_kong_id).to be_nil
      end
    end

    it "plans a CA certificate create, validated, with no key policy involved" do
      validate = stub_request(:post, "https://kong-admin.internal/schemas/ca_certificates/validate").to_return(ok)

      plan = planner(entity_type: "ca_certificate", operation: "create", attributes: { "cert" => pem }).call

      expect(plan).to be_persisted
      expect(validate).to have_been_requested
    end
  end
```

- [ ] **Step 2: Run to verify they fail**

Run: `bundle exec rspec -r "$K" spec/services/kong/change_planner_spec.rb`
Expected: FAIL — the policy examples raise nothing (a PEM key is accepted into a plan!), SNI create raises `MissingParent` not at all, PR-mode examples make a `POST /schemas/...`.

- [ ] **Step 3: Implement**

In `app/services/kong/change_planner.rb` (Edit tool):

1. Replace the whole `call` method. The only new lines are the `Kong::CertificateKeyPolicy.check!` block, placed right after the write-access guardrail so a bad key is refused before any request reaches Kong:

```ruby
    def call
      Kong::ChangeGuardrails.check_write_access!(connection: @connection)
      Kong::CertificateKeyPolicy.check!(
        @attributes, entity_type: @entity_type, apply_mode: @connection.apply_mode, operation: @operation
      )
      Kong::ChangeGuardrails.check_plugin_immutable!(
        connection: @connection, entity_type: @entity_type,
        target: @operation == "create" ? nil : { "id" => @target_kong_id },
        scope_kong_id: @operation == "create" ? plugin_scope_kong_id : nil
      )

      @parent_kong_id = resolve_parent_kong_id

      before = @operation == "create" ? {} : fetch_current

      if @actor_kind == "agent" && @operation == "delete"
        Kong::ChangeGuardrails.check_delete_confirmation!(
          connection: @connection, entity: before, confirmation_name: nil, actor_kind: "agent"
        )
      end

      after = compute_after(before)
      validate_against_kong_schema!(after)

      ChangePlan.create!(
        kong_connection: @connection,
        actor_username: @actor_username,
        actor_operator: @actor_operator,
        actor_kind: @actor_kind,
        operation: @operation,
        entity_type: @entity_type,
        target_kong_id: @target_kong_id,
        parent_kong_id: @parent_kong_id,
        before: before,
        after: after || {},
        diff: compute_diff(before, after),
        apply_mode: @connection.apply_mode,
        base_updated_at: before["updated_at"] ? Time.zone.at(before["updated_at"]) : nil,
        status: "pending",
        expires_at: ChangePlan::DEFAULT_TTL.from_now
      )
    end
```

2. Replace `resolve_parent_kong_id`:

```ruby
    # A nested type (target) can't build any Admin API path without its
    # parent; a flat child (sni) needs it in the create body. An update/delete
    # may omit it -- the read-model's own record is the authority, and for a
    # flat child a missing one is fine (no path depends on it; the applier only
    # uses it to refresh the parent afterwards).
    def resolve_parent_kong_id
      return @parent_kong_id if @parent_kong_id.present?
      return nil unless @definition.requires_parent?

      found = @operation == "create" ? nil : cached_parent_kong_id
      return found if found.present?
      return nil if !@definition.nested? && @operation != "create"

      remedy = @operation == "create" ? "pick a #{@definition.parent_type}" : "sync this connection first, then retry"
      raise MissingParent, "can't tell which #{@definition.parent_type} this #{@entity_type} belongs to -- #{remedy}"
    end
```

3. In `compute_after`, add the parent reference for a flat child's create:

```ruby
    def compute_after(before)
      case @operation
      when "create" then with_parent_reference(Kong::Redactor.prune_marked(@attributes))
      when "update" then Kong::Redactor.prune_marked(before.merge(@attributes))
      when "delete" then nil
      end
    end

    # An SNI's create body carries `certificate: {id}` -- the only way Kong
    # learns the parent, since the path is flat.
    def with_parent_reference(attributes)
      return attributes unless @definition.parent_in_body && @parent_kong_id.present?

      attributes.merge(@definition.parent_type => { "id" => @parent_kong_id })
    end
```

4. Replace the whole `validate_against_kong_schema!` method. New: the PR-mode early return, and injecting the parent for every `requires_parent?` type (it was `nested?` only). The `rescue` is the M5a code, unchanged:

```ruby
    def validate_against_kong_schema!(after)
      return unless @definition.schema_name && after
      # PR mode reads Kong through a read-only route, which answers any POST
      # with the router's 404; `deck gateway validate` covers PR mode in CI.
      return if @connection.apply_mode == "pr"

      body = after.except(*Kong::EntityTypes::KONG_MANAGED_FIELDS)
      body = body.merge(@definition.parent_type => { "id" => @parent_kong_id }) if @definition.requires_parent? && @parent_kong_id.present?
      @client.post("/schemas/#{@definition.schema_name}/validate", body: body)
    rescue Kong::Client::UnexpectedResponse => e
      raise unless e.response&.status == 400

      raise SchemaViolation, "Kong rejected this #{@entity_type}: #{schema_violation_message(e.response)}"
    end
```

`plugin_scope_kong_id` and everything else stay as they are.

- [ ] **Step 4: Run to verify they pass**

Run: `bundle exec rspec -r "$K" spec/services/kong/change_planner_spec.rb`
Expected: PASS, including every M5a example (a target's validate body still gets its `upstream` reference because `requires_parent?` is true for nested types).

- [ ] **Step 5: Run the whole suite and commit**

Run: `bundle exec rspec -r "$K"` — expected 0 failures.

```bash
git add app/services/kong/change_planner.rb spec/services/kong/change_planner_spec.rb
git commit -m "feat(m5b): enforce the key policy at plan time; SNI parents; no schema POST in PR mode"
```

### Task 7: Applier — re-check the policy, require the acknowledgement, record it, keep the read-model honest

**Files:**
- Create: `db/migrate/20260921120000_add_context_to_audit_events.rb`
- Modify: `db/schema.rb` (regenerated by the migration), `app/services/kong/change_applier.rb`
- Test: `spec/services/kong/change_applier_spec.rb` (extend)

**Interfaces:**
- Consumes: `Kong::CertificateKeyPolicy.check!` / `.env_vars_for` (Task 1), `Kong::EntitySync.sync_one` (exists), `Definition#parent_in_body` (Task 4).
- Produces:
  - `Kong::ChangeApplier.new(change_plan:, client:, actor_username:, actor_operator: nil, confirmation_name: nil, secret: nil, env_acknowledged: false)`.
  - `AuditEvent#context` (jsonb, default `{}`): `{"acknowledged_env_vars" => ["CERT_X_KEY"]}` when a vault-referenced key was applied.
  - After an SNI create/update/delete its parent certificate row is re-synced (failure ignored); after **any** delete, read-model rows whose `parent_kong_id` is the deleted entity are soft-deleted (Kong cascades: certificate → SNIs, upstream → targets).

- [ ] **Step 1: Add the migration**

Read a sibling (`db/migrate/20260901094858_create_audit_events.rb`) for the `ActiveRecord::Migration[x.y]` version tag and match it. Create `db/migrate/20260921120000_add_context_to_audit_events.rb`:

```ruby
# A general slot for facts about an audit event that do not deserve a column
# of their own. M5b puts {"acknowledged_env_vars" => [...]} here: which env
# vars an operator (or agent) confirmed exist before a certificate key
# reference was applied. AuditEvent stays append-only (readonly? unchanged).
class AddContextToAuditEvents < ActiveRecord::Migration[8.1]
  def change
    add_column :audit_events, :context, :jsonb, default: {}, null: false
  end
end
```

Run against the test database (this dumps `db/schema.rb`):

```bash
RAILS_ENV=test bin/rails db:migrate
git diff db/schema.rb
```

Expected: the diff is the `version:` bump and one added line `t.jsonb "context", default: {}, null: false` inside `audit_events` — nothing else. If unrelated schema churn appears, `git checkout db/schema.rb` and re-run with only that migration pending.

- [ ] **Step 2: Write the failing tests**

Add `require Rails.root.join("spec/support/pem_fixtures")` to the top of `spec/services/kong/change_applier_spec.rb`, then insert before the final `end`:

```ruby
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
```

- [ ] **Step 3: Run to verify they fail**

Run: `bundle exec rspec -r "$K" spec/services/kong/change_applier_spec.rb`
Expected: FAIL — `unknown keyword: :env_acknowledged`, no `context` on `AuditEvent`, no cascade.

- [ ] **Step 4: Implement**

In `app/services/kong/change_applier.rb` (Edit tool):

1. Replace the constructor (new: the `env_acknowledged:` keyword and the two ivars `@env_acknowledged`, `@env_vars`):

```ruby
    def initialize(change_plan:, client:, actor_username:, actor_operator: nil, confirmation_name: nil, secret: nil,
                    env_acknowledged: false)
      @change_plan = change_plan
      @connection = change_plan.kong_connection
      @client = client
      @actor_username = actor_username
      @actor_operator = actor_operator
      @confirmation_name = confirmation_name
      @secret = secret
      @env_acknowledged = env_acknowledged
      @env_vars = []
      @definition = Kong::EntityTypes.fetch(change_plan.entity_type)
    end
```

2. In `call`, after the `check_plugin_immutable!` block and before the delete-confirmation block, add:

```ruby
      # M5b: re-check the key policy against the *current* apply_mode (a plan
      # can sit pending 15 minutes) and demand the env-var acknowledgement.
      Kong::CertificateKeyPolicy.check!(
        @change_plan.after, entity_type: @change_plan.entity_type, apply_mode: @connection.apply_mode,
        operation: @change_plan.operation
      )
      require_env_acknowledgement!
```

3. Private helpers:

```ruby
    # Kong accepts a broken {vault://env/...} reference silently and the
    # hostname's TLS then fails (M5b spec section 1), and this tool cannot see
    # Kong's environment. So the operator (or agent) must state, out of band,
    # that the variable exists on every node.
    def require_env_acknowledgement!
      @env_vars = Kong::CertificateKeyPolicy.env_vars_for(@change_plan)
      return if @env_vars.empty? || @env_acknowledged

      raise Kong::ChangeGuardrails::Violation,
        "this makes Kong read #{@env_vars.join(', ')} -- confirm that variable is set on every Kong node " \
        "(acknowledge_env_vars) before applying; Kong won't notice if it is missing"
    end

    # After a child write, the parent's derived name/logical_key may have moved
    # (a certificate is named by its first SNI). The write already happened, so
    # a failed refresh must not fail the apply -- the next sync corrects it.
    def refresh_parent_certificate(parent_kong_id)
      return if parent_kong_id.blank?

      Kong::EntitySync.sync_one(connection: @connection, client: @client, entity_type: "certificate", kong_id: parent_kong_id)
    rescue Kong::Client::Error
      nil
    end

    # Kong deletes a certificate's SNIs and an upstream's targets with it;
    # without this the read-model would keep listing them until the next sync.
    def soft_delete_children
      KongEntity.active
        .where(kong_connection: @connection, parent_kong_id: @change_plan.target_kong_id)
        .update_all(deleted_at: Time.current)
    end
```

4. Hook them into the executors. In `execute_create!` and `execute_update!` capture the upserted entity and refresh for SNIs:

```ruby
    def execute_create!
      response = @client.post(@definition.create_path(parent_kong_id: @change_plan.parent_kong_id), body: @change_plan.after)
      entity = Kong::EntitySync.new(connection: @connection, client: @client, entity_type: @change_plan.entity_type).upsert(parse(response))
      refresh_parent_certificate(entity.parent_kong_id) if @change_plan.entity_type == "sni"
    end
```

(the same two-line change in `execute_update!`), and in `execute_delete!` append after the existing `update_all`:

```ruby
      soft_delete_children
      refresh_parent_certificate(@change_plan.before.dig("certificate", "id") || @change_plan.parent_kong_id) if @change_plan.entity_type == "sni"
```

5. `record_audit_event!` — add `context:`:

```ruby
        context: @env_vars.present? ? { "acknowledged_env_vars" => @env_vars } : {},
```

- [ ] **Step 5: Run to verify they pass, then everything**

Run: `bundle exec rspec -r "$K" spec/services/kong/change_applier_spec.rb` — expected PASS.
Run: `bundle exec rspec -r "$K"` — expected 0 failures.

- [ ] **Step 6: Commit**

```bash
git add db/migrate/20260921120000_add_context_to_audit_events.rb db/schema.rb app/services/kong/change_applier.rb spec/services/kong/change_applier_spec.rb
git commit -m "feat(m5b): env-var acknowledgement, policy re-check and child cascade in the applier"
```

---

### Task 8: Browse certificates — tabs, list columns, expiry badges, detail page

**Files:**
- Modify: `app/helpers/application_helper.rb`, `app/helpers/entities_helper.rb`, `app/controllers/entities_controller.rb`, `app/views/entities/index.html.erb`, `app/views/entities/_entity_row.html.erb`, `app/views/entities/show.html.erb`
- Create: `app/views/entities/_certificate_details.html.erb`
- Test: `spec/requests/entities_spec.rb` (extend), `spec/helpers/application_helper_spec.rb` (extend)

**Interfaces:**
- Consumes: `KongEntity#expiry_status` (Task 4), `data["_metadata"]` (Task 5), `Kong::CertificateKeyPolicy.env_var_name` / `.vault_reference?` (Task 1).
- Produces: `entity_type_label` for the three types; helpers `expiry_badge(entity)` and `expiry_when(entity)`; tabs **Certificates** and **CA certificates**; a certificate detail page with metadata, the key reference and the env var it reads, and an **SNIs** child group with an **Add SNI** link to `new_entity_path(type: "sni", parent_kong_id: <certificate kong_id>)`.

- [ ] **Step 1: Write the failing tests**

Append inside `RSpec.describe ApplicationHelper` in `spec/helpers/application_helper_spec.rb` (read the file's existing `helper` usage first and match it):

```ruby
  describe "certificate helpers (M5b)" do
    it "labels the three types" do
      expect(helper.entity_type_label("certificate")).to eq("Certificates")
      expect(helper.entity_type_label("certificate", count: 1)).to eq("Certificate")
      expect(helper.entity_type_label("ca_certificate")).to eq("CA certificates")
      expect(helper.entity_type_label("sni", count: 1)).to eq("SNI")
    end

    it "renders an expiry badge per tier, and a dash when there is nothing to expire" do
      %w[expired critical warning ok].each do |status|
        entity = build(:kong_entity, not_after: 1.day.from_now)
        allow(entity).to receive(:expiry_status).and_return(status)
        expect(helper.expiry_badge(entity)).to include(status.capitalize)
      end
      expect(helper.expiry_badge(build(:kong_entity, not_after: nil))).to include("—")
    end

    it "describes expiry in words, past and future" do
      expect(helper.expiry_when(build(:kong_entity, not_after: 12.days.from_now))).to eq("in 12 days")
      expect(helper.expiry_when(build(:kong_entity, not_after: 3.days.ago))).to eq("3 days ago")
      expect(helper.expiry_when(build(:kong_entity, not_after: nil))).to be_nil
    end
  end
```

Append a `describe` inside `RSpec.describe "Entities (web)"` in `spec/requests/entities_spec.rb`, before the final `end`. Add `require Rails.root.join("spec/support/pem_fixtures")` at the file top.

```ruby
  describe "certificates (M5b)" do
    let(:cert_id) { "dddddddd-0000-0000-0000-00000000000d" }
    let(:sni_id) { "eeeeeeee-0000-0000-0000-00000000000e" }
    let(:metadata) do
      { "subject" => "CN=pay.example.internal,O=Spec", "issuer" => "CN=Spec CA", "serial" => "ABC123",
        "not_before" => 1.day.ago.iso8601, "not_after" => 12.days.from_now.iso8601,
        "fingerprint_sha256" => "a" * 64, "sans" => [ "DNS:pay.example.internal" ] }
    end

    def create_certificate(name: "pay.example.internal", key: "{vault://env/cert-pay-key}", not_after: 12.days.from_now, **attrs)
      create(:kong_entity, kong_connection: connection, entity_type: "certificate", kong_id: cert_id, name: name, not_after: not_after,
        data: { "key" => key, "snis" => [ name ], "_metadata" => metadata }, **attrs)
    end

    it "has Certificates and CA certificates tabs" do
      sign_in

      get entities_path(type: "certificate")

      expect(response.body).to include("Certificates").and include("CA certificates")
    end

    it "lists certificates with an expiry badge and how long is left" do
      sign_in
      create_certificate
      create(:kong_entity, kong_connection: connection, entity_type: "certificate", name: "gone.example", not_after: 2.days.ago,
        data: { "_metadata" => metadata })

      get entities_path(type: "certificate")

      expect(response.body).to include("pay.example.internal").and include("gone.example")
      expect(response.body).to include("Warning") # 12 days left
      expect(response.body).to include("Expired")
      expect(response.body).to include("2 days ago")
    end

    it "shows how many SNIs each certificate has" do
      sign_in
      create(:kong_entity, kong_connection: connection, entity_type: "certificate", name: "multi.example", not_after: 90.days.from_now,
        data: { "snis" => %w[multi.example a.example b.example], "_metadata" => metadata })

      get entities_path(type: "certificate")

      expect(response.body).to include("SNIs") # column header
      expect(response.body).to match(/tabular-nums[^>]*>\s*3\s*</)
    end

    it "lists CA certificates the same way" do
      sign_in
      create(:kong_entity, kong_connection: connection, entity_type: "ca_certificate", name: "9852b7219ac3", not_after: 400.days.from_now,
        data: { "_metadata" => metadata })

      get entities_path(type: "ca_certificate")

      expect(response.body).to include("9852b7219ac3").and include("Ok")
    end

    it "shows a certificate's metadata, and the env var its key reference reads" do
      sign_in
      certificate = create_certificate

      get entity_path(certificate)

      expect(response.body).to include("CN=pay.example.internal,O=Spec").and include("CN=Spec CA")
      expect(response.body).to include("a" * 64)
      expect(response.body).to include("DNS:pay.example.internal")
      expect(response.body).to include("{vault://env/cert-pay-key}")
      expect(response.body).to include("CERT_PAY_KEY")
    end

    it "warns when Kong still holds a plaintext key, since the tool can never have set it" do
      sign_in
      certificate = create_certificate(key: "[REDACTED]")

      get entity_path(certificate)

      expect(response.body).to include("plaintext")
      expect(response.body).not_to include("PRIVATE KEY")
    end

    it "shows the certificate's SNIs with an Add SNI link scoped to it" do
      sign_in
      certificate = create_certificate
      create(:kong_entity, kong_connection: connection, entity_type: "sni", kong_id: sni_id, name: "api.example.internal",
        parent_type: "certificate", parent_kong_id: cert_id, enabled: nil)

      get entity_path(certificate)

      expect(response.body).to include("SNIs").and include("api.example.internal")
      expect(response.body).to include(new_entity_path(type: "sni", parent_kong_id: cert_id).gsub("&", "&amp;"))
      expect(response.body).not_to include(">disabled<")
    end

    it "does not show certificate panels on other entity types" do
      sign_in
      service = create(:kong_entity, kong_connection: connection, entity_type: "service", name: "payments-api")

      get entity_path(service)

      expect(response.body).not_to include("Key reference")
    end
  end
```

- [ ] **Step 2: Run to verify they fail**

Run: `bundle exec rspec -r "$K" spec/helpers spec/requests/entities_spec.rb`
Expected: FAIL — no `expiry_badge`, `entity_type_label("certificate")` humanizes wrongly, tabs missing.

- [ ] **Step 3: Implement the helpers**

`app/helpers/application_helper.rb` — add the labels to `ENTITY_TYPE_LABELS`:

```ruby
    "certificate" => %w[Certificate Certificates],
    "ca_certificate" => ["CA certificate", "CA certificates"],
    "sni" => %w[SNI SNIs]
```

(comma after the previous `"target"` entry). Add expiry tones to `STATUS_TONE` (danger for the two urgent tiers, the existing warn palette for `warning`; `ok` already exists):

```ruby
    "expired" => { dot: "#a3312a", bg: "#f8ecea", text: "#6e2015" },
    "critical" => { dot: "#a3312a", bg: "#f8ecea", text: "#6e2015" },
    "warning" => { dot: "#93600f", bg: "#f7efe0", text: "#5c4a14" },
```

Add public helper methods (before the `private` line):

```ruby
  # M5b: the badge and the words for a certificate's expiry. A dash for
  # anything with no not_after (every non-certificate entity, or a PEM that
  # would not parse) -- never a guess.
  def expiry_badge(entity)
    status = entity.expiry_status
    return content_tag(:span, "—", style: "color: var(--color-ink-faint)") unless status

    status_badge(status)
  end

  def expiry_when(entity)
    return nil unless entity.not_after

    distance = time_ago_in_words(entity.not_after)
    entity.not_after <= Time.current ? "#{distance} ago" : "in #{distance}"
  end
```

`app/helpers/entities_helper.rb` — add columns to `ENTITY_TABLE_COLUMNS` (SNIs use the default service columns) and widen the table for them:

```ruby
    "certificate" => [
      [ "Name", "minmax(160px, 1.2fr)" ],
      [ "SNIs", "minmax(64px, 0.4fr)" ],
      [ "Expires", "minmax(200px, 1.3fr)" ],
      [ "Tags", "minmax(120px, 0.9fr)" ],
      [ "Status", "minmax(96px, auto)" ],
      [ "Updated", "minmax(92px, auto)" ]
    ],
    "ca_certificate" => [
      [ "Name", "minmax(160px, 1.2fr)" ],
      [ "Expires", "minmax(200px, 1.3fr)" ],
      [ "Tags", "minmax(120px, 0.9fr)" ],
      [ "Status", "minmax(96px, auto)" ],
      [ "Updated", "minmax(92px, auto)" ]
    ]
```

and `type.in?(%w[route plugin upstream target certificate ca_certificate]) ? "820px" : "620px"` in `entity_table_min_width`. Add a small key summary helper:

```ruby
  # What the certificate page says about a certificate's private key: the
  # reference and the env var it reads, "plaintext" when Kong still holds one
  # (the redactor blanked it -- this tool never sets one), or nil.
  def certificate_key_summary(entity)
    key = entity.data["key"]
    if Kong::CertificateKeyPolicy.vault_reference?(key)
      { kind: :reference, value: key, env_var: Kong::CertificateKeyPolicy.env_var_name(key) }
    elsif key == Kong::Redactor::MARK
      { kind: :plaintext }
    end
  end
```

- [ ] **Step 4: Implement the controller and views**

`app/controllers/entities_controller.rb` — in `child_groups` add before `else`:

```ruby
    when "certificate"
      { "SNIs" => children_of("sni") }
```

`app/views/entities/index.html.erb` — change the tab list to `%w[service route consumer plugin upstream certificate ca_certificate]`.

`app/views/entities/_entity_row.html.erb` — add after the `upstream`/`target` cells (the SNI count sits between Name and Expires, matching the column order above; a CA certificate has no SNIs, so it gets no count cell):

```erb
  <% if type == "certificate" %>
    <span class="entity-cell font-mono text-xs tabular-nums" style="color: var(--color-ink-soft)"><%= Array(entity.data["snis"]).size %></span>
  <% end %>

  <% if type.in?(%w[certificate ca_certificate]) %>
    <div class="entity-cell flex flex-wrap items-center gap-1.5">
      <%= expiry_badge(entity) %>
      <% if entity.not_after %>
        <span class="text-xs" style="color: var(--color-ink-soft)"><%= expiry_when(entity) %></span>
      <% end %>
    </div>
  <% end %>
```

Create `app/views/entities/_certificate_details.html.erb`:

```erb
<%# Metadata parsed from the PEM at sync time (Kong::CertificateMetadata). The
    PEM itself is never cached, and the private key is only ever a reference. %>
<% meta = @entity.data["_metadata"] || {} %>
<% key = certificate_key_summary(@entity) if @entity.entity_type == "certificate" %>

<section class="panel p-4">
  <h2 class="section-label mb-3">Certificate</h2>
  <% if meta["parse_error"] %>
    <p class="text-sm" style="color: var(--color-warning)">Kong's copy of this certificate couldn't be read here (<%= meta["parse_error"] %>), so no details are shown.</p>
  <% else %>
    <dl class="grid grid-cols-[max-content_1fr] gap-x-6 gap-y-2 text-sm">
      <dt style="color: var(--color-ink-soft)">Expires</dt>
      <dd class="flex flex-wrap items-center gap-2"><%= expiry_badge(@entity) %> <%= @entity.not_after&.to_fs(:long) %> <span style="color: var(--color-ink-soft)">(<%= expiry_when(@entity) %>)</span></dd>
      <dt style="color: var(--color-ink-soft)">Valid from</dt><dd><%= meta["not_before"] && Time.iso8601(meta["not_before"]).to_fs(:long) %></dd>
      <dt style="color: var(--color-ink-soft)">Subject</dt><dd class="font-mono text-xs break-all"><%= meta["subject"] %></dd>
      <dt style="color: var(--color-ink-soft)">Issuer</dt><dd class="font-mono text-xs break-all"><%= meta["issuer"] %></dd>
      <dt style="color: var(--color-ink-soft)">SANs</dt><dd class="font-mono text-xs"><%= Array(meta["sans"]).join(", ").presence || "—" %></dd>
      <dt style="color: var(--color-ink-soft)">Serial</dt><dd class="font-mono text-xs break-all"><%= meta["serial"] %></dd>
      <dt style="color: var(--color-ink-soft)">SHA-256</dt><dd class="font-mono text-xs break-all"><%= meta["fingerprint_sha256"] %></dd>
    </dl>
  <% end %>
</section>

<% if key %>
  <section class="panel p-4">
    <h2 class="section-label mb-3">Key reference</h2>
    <% if key[:kind] == :reference %>
      <dl class="grid grid-cols-[max-content_1fr] gap-x-6 gap-y-2 text-sm">
        <dt style="color: var(--color-ink-soft)">Reference</dt><dd class="font-mono text-xs break-all"><%= key[:value] %></dd>
        <dt style="color: var(--color-ink-soft)">Kong reads</dt><dd class="font-mono text-xs"><%= key[:env_var] %></dd>
      </dl>
      <p class="text-xs mt-3" style="color: var(--color-ink-faint)">
        The private key lives only in that environment variable on each Kong node. Kong doesn't check that it is set —
        if it is missing, TLS for this certificate's hostnames fails.
      </p>
    <% else %>
      <p class="text-sm" style="color: var(--color-warning)">
        Kong holds a plaintext private key for this certificate. This tool never sets one and can't show it — replace it
        with a <code class="font-mono">{vault://env/…}</code> reference when you next edit the certificate.
      </p>
    <% end %>
  </section>
<% end %>
```

`app/views/entities/show.html.erb` — render the partial after the Overview `</section>` (before the Raw JSON section) and add the SNI link. Insert:

```erb
  <% if @entity.entity_type.in?(%w[certificate ca_certificate]) %>
    <%= render "certificate_details" %>
  <% end %>
```

and in the child-group header, extend the existing `if label == "Plugins" ... elsif label == "Targets"` chain with:

```erb
        <% elsif label == "SNIs" %>
          <%= link_to "Add SNI", new_entity_path(type: "sni", parent_kong_id: @entity.kong_id), class: "btn-text px-2 py-1 text-xs" %>
```

- [ ] **Step 5: Run to verify they pass, then everything**

Run: `bundle exec rspec -r "$K" spec/helpers spec/requests/entities_spec.rb` — PASS. Then `bundle exec rspec -r "$K"` — 0 failures.

- [ ] **Step 6: Normalize line endings and commit**

```bash
sed -i 's/\r$//; s/$/\r/' app/views/entities/_certificate_details.html.erb
git add app/helpers app/controllers/entities_controller.rb app/views/entities spec/helpers spec/requests/entities_spec.rb
git commit -m "feat(m5b): browse certificates and CA certificates with expiry"
```

### Task 9: Create and edit certificates, CA certificates and SNIs in the web UI

**Files:**
- Modify: `app/controllers/entities_controller.rb`, `app/views/entities/index.html.erb`, `app/views/entities/new.html.erb`, `app/views/entities/edit.html.erb`
- Test: `spec/requests/entities_spec.rb` (extend)

**Interfaces:**
- Consumes: `Kong::CertificateKeyPolicy.scrub` and `::Rejected` (Task 1), the planner's enforcement (Task 6), `Definition#requires_parent?` (Task 4), the M5a `new`/`create` actions and `render_new_with_error`.
- Produces: `EntitiesController::CREATABLE_TYPES` includes `certificate ca_certificate sni`; `GET /entities/new?type=certificate|ca_certificate|sni[&parent_kong_id=]` with seeded JSON; a certificate form whose seeded key is a **deliberately invalid** placeholder (`{vault://env/cert-NAME-key}`, uppercase fails the policy) so an unedited submit is refused instead of creating a certificate that points at a variable nobody set; every re-rendered editor has private-key blocks scrubbed from the echoed text.

- [ ] **Step 1: Write the failing tests**

Append a `describe` to `spec/requests/entities_spec.rb` (before the final `end`), reusing the `describe "certificates (M5b)"` `let`s by placing it **inside** that block, after the last example:

```ruby
    describe "forms" do
      let(:ok) { { status: 200, body: { message: "schema validation successful" }.to_json } }
      let(:pem) { PemFixtures.self_signed(days: 60) }
      let(:private_key_pem) { pem[:key_pem] }

      it "opens a certificate form seeded with a key placeholder that must be edited, and explains the reference" do
        sign_in

        get new_entity_path(type: "certificate")

        expect(response).to have_http_status(:ok)
        expect(response.body).to include("New certificate")
        expect(response.body).to include("{vault://env/cert-NAME-key}")
        expect(response.body).to include("CERT_PAYMENTS_KEY")
        expect(response.body).to include("can't be pasted") # static template text, not user content, so not HTML-escaped
      end

      it "mentions the decK placeholder only on a PR-mode connection" do
        sign_in
        get new_entity_path(type: "certificate")
        expect(response.body).not_to include("DECK_")

        connection.update!(apply_mode: "pr")
        get new_entity_path(type: "certificate")
        expect(response.body).to include("DECK_")
      end

      it "opens CA certificate and SNI forms" do
        sign_in
        create_certificate

        get new_entity_path(type: "ca_certificate")
        expect(response.body).to include("New CA certificate")
        expect(response.body).not_to include("&quot;key&quot;")

        get new_entity_path(type: "sni", parent_kong_id: cert_id)
        expect(response.body).to include("certificate: pay.example.internal")
      end

      it "sends an SNI form with no known certificate back to the certificate list" do
        sign_in

        get new_entity_path(type: "sni", parent_kong_id: cert_id)

        expect(response).to redirect_to(entities_path(type: "certificate"))
      end

      it "offers New certificate and New CA certificate buttons on their own tabs only" do
        sign_in

        get entities_path(type: "certificate")
        expect(response.body).to include("New certificate")
        get entities_path(type: "ca_certificate")
        expect(response.body).to include("New CA certificate")
        get entities_path(type: "service")
        expect(response.body).not_to include("New certificate")
      end

      it "proposes a certificate whose key is a vault reference" do
        sign_in
        validate = stub_request(:post, "https://kong-admin.test/schemas/certificates/validate").to_return(ok)

        post entities_path, params: { type: "certificate",
          payload_json: { cert: pem[:cert_pem], key: "{vault://env/cert-pay-key}", snis: [ "pay.example.internal" ] }.to_json }

        plan = ChangePlan.last
        expect(response).to redirect_to(change_plan_path(plan))
        expect(plan.entity_type).to eq("certificate")
        expect(plan.after["key"]).to eq("{vault://env/cert-pay-key}")
        expect(validate).to have_been_requested
      end

      it "refuses a pasted private key: 422, a fix in the message, no plan, no Kong call, and the key is not echoed back" do
        sign_in

        post entities_path, params: { type: "certificate", payload_json: { cert: pem[:cert_pem], key: private_key_pem }.to_json }

        expect(response).to have_http_status(:unprocessable_entity)
        expect(response.body).to include("{vault://env/")
        expect(response.body).to include("private key removed")
        expect(response.body).not_to include("PRIVATE KEY")
        expect(response.body).not_to include(private_key_pem.lines[1].strip)
        expect(ChangePlan.count).to eq(0)
        expect(WebMock).not_to have_requested(:post, /schemas/)
      end

      it "refuses the unedited seed, whose NAME placeholder is not a valid reference" do
        sign_in

        post entities_path, params: { type: "certificate",
          payload_json: { cert: pem[:cert_pem], key: "{vault://env/cert-NAME-key}", snis: [], tags: [] }.to_json }

        expect(response).to have_http_status(:unprocessable_entity)
        expect(ChangePlan.count).to eq(0)
      end

      it "refuses a decK placeholder on a direct-mode connection" do
        sign_in

        post entities_path, params: { type: "certificate", payload_json: { cert: pem[:cert_pem], key: '${{ env "DECK_CERT_A" }}' }.to_json }

        expect(response).to have_http_status(:unprocessable_entity)
        expect(response.body).to include("PR mode")
      end

      it "does not echo a private key even when the JSON is malformed" do
        sign_in
        broken = "{ \"key\": \"#{private_key_pem.gsub("\n", '\n')}\" oops"

        post entities_path, params: { type: "certificate", payload_json: broken }

        expect(response).to have_http_status(:unprocessable_entity)
        expect(response.body).not_to include("BEGIN PRIVATE KEY")
        expect(response.body).to include("private key removed")
      end

      it "proposes an SNI under its certificate, carrying the reference" do
        sign_in
        create_certificate
        stub_request(:post, "https://kong-admin.test/schemas/snis/validate").to_return(ok)

        post entities_path, params: { type: "sni", parent_kong_id: cert_id, payload_json: { name: "api.example.internal" }.to_json }

        plan = ChangePlan.last
        expect(response).to redirect_to(change_plan_path(plan))
        expect(plan.after).to eq({ "name" => "api.example.internal", "certificate" => { "id" => cert_id } })
      end

      it "proposes a CA certificate" do
        sign_in
        stub_request(:post, "https://kong-admin.test/schemas/ca_certificates/validate").to_return(ok)

        post entities_path, params: { type: "ca_certificate", payload_json: { cert: pem[:cert_pem] }.to_json }

        expect(ChangePlan.last.entity_type).to eq("ca_certificate")
      end

      it "refuses a PEM typed into key_alt from the certificate editor, and re-renders without it" do
        sign_in
        certificate = create_certificate
        stub_request(:get, "https://kong-admin.test/certificates/#{cert_id}").to_return(status: 200, body: {
          id: cert_id, cert: pem[:cert_pem], key: "{vault://env/cert-pay-key}", snis: [ "pay.example.internal" ], tags: [], updated_at: 1_700_000_000
        }.to_json)

        patch entity_path(certificate), params: { payload_json: { key_alt: private_key_pem }.to_json }

        expect(response).to have_http_status(:unprocessable_entity)
        expect(response.body).to include("key_alt")
        expect(response.body).not_to include("BEGIN PRIVATE KEY")
        expect(ChangePlan.count).to eq(0)
      end

      it "opens the certificate editor on the live document, with the reference and no plaintext hint about redaction" do
        sign_in
        certificate = create_certificate
        stub_request(:get, "https://kong-admin.test/certificates/#{cert_id}").to_return(status: 200, body: {
          id: cert_id, cert: pem[:cert_pem], key: "{vault://env/cert-pay-key}", snis: [ "pay.example.internal" ], tags: [], updated_at: 1_700_000_000
        }.to_json)

        get edit_entity_path(certificate)

        expect(response.body).to include("{vault://env/cert-pay-key}")
        expect(response.body).to include("reference")
        expect(response.body).not_to include("can&#39;t be set here")
      end
    end
```

- [ ] **Step 2: Run to verify they fail**

Run: `bundle exec rspec -r "$K" spec/requests/entities_spec.rb -e "forms"`
Expected: FAIL — `There's no create form for "certificate"`, buttons missing.

- [ ] **Step 3: Implement the controller**

In `app/controllers/entities_controller.rb`:

1. Extend the constants:

```ruby
  CREATABLE_TYPES = %w[upstream target certificate ca_certificate sni].freeze
  TARGET_SEED = { "target" => "", "weight" => 100, "tags" => [] }.freeze
  # The certificate seed's key is *deliberately* an invalid reference (upper
  # case fails Kong::CertificateKeyPolicy): submitted unedited it is refused,
  # rather than creating a certificate pointing at a variable nobody set.
  CERTIFICATE_SEED = {
    "cert" => "-----BEGIN CERTIFICATE-----\n...\n-----END CERTIFICATE-----\n",
    "key" => "{vault://env/cert-NAME-key}",
    "snis" => [],
    "tags" => []
  }.freeze
  CA_CERTIFICATE_SEED = { "cert" => "-----BEGIN CERTIFICATE-----\n...\n-----END CERTIFICATE-----\n", "tags" => [] }.freeze
  SNI_SEED = { "name" => "", "tags" => [] }.freeze
```

2. Replace `seed_payload`:

```ruby
  def seed_payload
    case @creatable_type
    when "upstream" then Kong::UpstreamPresets.seed(params[:preset])
    when "target" then TARGET_SEED.deep_dup
    when "certificate" then CERTIFICATE_SEED.deep_dup
    when "ca_certificate" then CA_CERTIFICATE_SEED.deep_dup
    when "sni" then SNI_SEED.deep_dup
    end
  end
```

3. In `set_parent` change the guard from `return unless definition.nested?` to `return unless definition.requires_parent?`.

4. Never echo a private key back: add a helper and use it wherever the operator's text is put back on the page (`render_new_with_error`, and the `InvalidPayload` and `SchemaViolation` branches of `update`):

```ruby
  # The text an error page puts back in the editor. A private key someone
  # pasted is removed first -- it must not round-trip through our HTML.
  def echoed_payload
    Kong::CertificateKeyPolicy.scrub(params[:payload_json])
  end
```

`render_new_with_error` becomes `@payload_json = echoed_payload`; in `update` replace `@payload_json = params[:payload_json]` with `@payload_json = echoed_payload` in **both** places, and widen the second rescue:

```ruby
  rescue Kong::ChangePlanner::SchemaViolation, Kong::CertificateKeyPolicy::Rejected => e
    return redirect_to(edit_entity_path(@entity), alert: e.message) if params[:payload_json].blank?
    # ... rest unchanged
```

`Rejected` is a `Violation` subclass, so `create` already re-renders it through its existing `rescue ... Kong::ChangeGuardrails::Violation`.

- [ ] **Step 4: Implement the views**

`app/views/entities/index.html.erb` — extend the button chain:

```erb
    <% elsif @type == "certificate" %>
      <%= link_to "New certificate", new_entity_path(type: "certificate"), class: "btn-primary px-3.5 py-2 text-sm" %>
    <% elsif @type == "ca_certificate" %>
      <%= link_to "New CA certificate", new_entity_path(type: "ca_certificate"), class: "btn-primary px-3.5 py-2 text-sm" %>
```

`app/helpers/entities_helper.rb` — add a display name so the form title reads "New CA certificate", not "New ca_certificate" (every other creatable type's raw name already reads fine):

```ruby
  def creatable_type_name(type)
    { "ca_certificate" => "CA certificate" }.fetch(type.to_s, type.to_s)
  end
```

`app/views/entities/new.html.erb` — use it in the three places the raw type is printed: `content_for :title, "New #{creatable_type_name(@creatable_type)}"`, the `<h1>` (`New <%= creatable_type_name(@creatable_type) %>`), and the panel heading (`<%= creatable_type_name(@creatable_type).capitalize %> document` becomes `<%= creatable_type_name(@creatable_type).sub(/\A./, &:upcase) %> document`, which keeps "CA" intact). The M5a assertion `include("New upstream")` still holds because `creatable_type_name("upstream")` is `"upstream"`.

Then, in the same file, after the upstream presets `nav` block and before the `form_with`, add:

```erb
  <% if @creatable_type == "certificate" %>
    <section class="panel p-4 text-sm" style="color: var(--color-ink-soft)">
      <h2 class="section-label mb-2">Private key</h2>
      <p>
        A private key can't be pasted here. Set it as an environment variable on every Kong node, then reference it:
        <code class="font-mono">{vault://env/cert-payments-key}</code> makes Kong read
        <code class="font-mono">CERT_PAYMENTS_KEY</code>.
        <% if current_connection.apply_mode == "pr" %>
          In PR mode you can also use <code class="font-mono">${{ env "DECK_CERT_PAYMENTS_KEY" }}</code>, filled in by CI.
        <% end %>
      </p>
      <p class="mt-2">
        Kong doesn't check that the variable exists — if it is missing, TLS for this certificate's hostnames fails.
        You'll be asked to confirm it is set before this is applied.
      </p>
    </section>
  <% end %>
```

`app/views/entities/edit.html.erb` — replace the `Redactor::SENSITIVE_FIELDS_BY_ENTITY` `if` block (lines ~38-40) with:

```erb
        <% if @entity.entity_type == "certificate" %>
          The private key is a <em>reference</em> (<code class="font-mono">{vault://env/…}</code>); a key itself can't be entered here.
        <% elsif Kong::Redactor::SENSITIVE_FIELDS_BY_ENTITY.key?(@entity.entity_type) %>
          Secrets show as <code class="font-mono"><%= Kong::Redactor::MARK %></code> and can't be set here.
        <% end %>
```

- [ ] **Step 5: Run to verify they pass, then everything**

Run: `bundle exec rspec -r "$K" spec/requests/entities_spec.rb` — PASS. Then `bundle exec rspec -r "$K"` — 0 failures.

- [ ] **Step 6: Commit**

```bash
git add app/controllers/entities_controller.rb app/views/entities spec/requests/entities_spec.rb
git commit -m "feat(m5b): create and edit certificates, CA certificates and SNIs"
```

---

### Task 10: The review page — acknowledgement checkbox, SNI cascade warning, landing page

**Files:**
- Modify: `app/controllers/change_plans_controller.rb`, `app/views/change_plans/show.html.erb`
- Test: `spec/requests/change_plans_spec.rb` (extend)

**Interfaces:**
- Consumes: `Kong::CertificateKeyPolicy.env_vars_for(plan)` (Task 1), `Kong::ChangeApplier` `env_acknowledged:` (Task 7), `Definition#requires_parent?` (Task 4).
- Produces: `@env_vars` and `@dependent_snis` on `ChangePlansController#show`; a required-in-effect checkbox named `acknowledge_env_vars` (value `"1"`) on the apply form; applying without it redirects back with the applier's message; creating an SNI lands on its certificate's page.

- [ ] **Step 1: Write the failing tests**

Add `require Rails.root.join("spec/support/pem_fixtures")` at the top of `spec/requests/change_plans_spec.rb`, then insert before the final `end`:

```ruby
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
```

- [ ] **Step 2: Run to verify they fail**

Run: `bundle exec rspec -r "$K" spec/requests/change_plans_spec.rb -e "M5b"`
Expected: FAIL — no checkbox, apply ignores the param, no SNI warning.

- [ ] **Step 3: Implement the controller**

In `app/controllers/change_plans_controller.rb`:

1. `show` — add after `@dependent_targets = dependent_targets`:

```ruby
    @env_vars = @change_plan.status == "pending" ? Kong::CertificateKeyPolicy.env_vars_for(@change_plan) : []
    @dependent_snis = dependent_snis
```

2. `apply` — pass the acknowledgement:

```ruby
    result = Kong::ChangeApplier.new(
      change_plan: @change_plan, client: current_client,
      actor_username: current_connection.auth_username, actor_operator: current_operator,
      confirmation_name: params[:confirmation_name], secret: current_secret,
      env_acknowledged: params[:acknowledge_env_vars] == "1"
    ).call
```

3. Add `dependent_snis` next to `dependent_targets`:

```ruby
  # Kong removes a certificate's SNIs with it, so this is a heads-up about
  # what goes too, not a blocker.
  def dependent_snis
    return nil unless @change_plan.delete? && @change_plan.entity_type == "certificate"

    KongEntity.active.where(kong_connection: current_connection, entity_type: "sni", parent_kong_id: @change_plan.target_kong_id)
  end
```

4. `nested_parent_for` — a flat child (SNI) lands on its certificate too. Change the guard:

```ruby
    return nil unless definition.requires_parent? && change_plan.parent_kong_id.present?
```

- [ ] **Step 4: Implement the view**

`app/views/change_plans/show.html.erb` — after the `@dependent_targets` banner add:

```erb
<% if @dependent_snis.present? %>
  <p class="notice-banner mb-6" style="background: var(--color-warning-tint); border-color: var(--color-warning); color: var(--color-warning)">
    Deleting this certificate also removes its <%= @dependent_snis.size %> SNI<%= "s" unless @dependent_snis.size == 1 %>: <%= @dependent_snis.map(&:name).join(", ") %>
  </p>
<% end %>
```

and inside the apply `form_with`, before the `@requires_confirmation_name` block:

```erb
      <% if @env_vars.present? %>
        <div class="grid gap-2">
          <label class="flex items-start gap-2 text-sm" style="color: var(--color-ink)">
            <input type="checkbox" name="acknowledge_env_vars" value="1" required class="mt-0.5" style="accent-color: var(--color-accent)" />
            <span>
              I confirm <span class="font-mono"><%= @env_vars.join(", ") %></span>
              <%= @env_vars.size == 1 ? "is" : "are" %> set in the environment of every Kong node on <%= current_connection.name %>.
            </span>
          </label>
          <p class="text-xs" style="color: var(--color-ink-faint)">
            Kong doesn't check this. If a variable is missing, TLS for this certificate's hostnames fails until it is set.
          </p>
        </div>
      <% end %>
```

- [ ] **Step 5: Run to verify they pass, then everything**

Run: `bundle exec rspec -r "$K" spec/requests/change_plans_spec.rb` — PASS. Then `bundle exec rspec -r "$K"` — 0 failures.

- [ ] **Step 6: Commit**

```bash
git add app/controllers/change_plans_controller.rb app/views/change_plans spec/requests/change_plans_spec.rb
git commit -m "feat(m5b): acknowledgement checkbox, SNI cascade warning, SNI landing page"
```

### Task 11: Expiry dashboard (web, current connection)

**Files:**
- Create: `app/controllers/certificates_controller.rb`, `app/views/certificates/expiring.html.erb`
- Modify: `config/routes.rb`, `app/views/entities/index.html.erb`
- Test: `spec/requests/certificates_spec.rb` (create)

**Interfaces:**
- Consumes: `KongEntity.expiring_within(days)`, `#expiry_status` (Task 4), `expiry_badge` / `expiry_when` (Task 8), `require_session!` / `current_connection` (existing `ApplicationController`).
- Produces: `GET /certificates/expiring?days=N` (`expiring_certificates_path`) — certificates and CA certificates of the **current connection only**, expired ones included, soonest first; `days` accepts 1..3650 and falls back to 30.

- [ ] **Step 1: Write the failing test**

Create `spec/requests/certificates_spec.rb`:

```ruby
require "rails_helper"

RSpec.describe "Certificates expiring (web)", type: :request do
  let(:connection) { create(:kong_connection, admin_url: "https://kong-admin.test", credential_mode: "session") }

  def sign_in
    stub_request(:get, "https://kong-admin.test/").to_return(status: 200, body: { version: "3.7.0" }.to_json)
    stub_request(:patch, "https://kong-admin.test#{Kong::AccessProbe::PROBE_PATH}").to_return(status: 404, body: { message: "Not found" }.to_json)
    stub_request(:get, "https://kong-admin.test/consumers/alice").to_return(status: 200, body: { tags: [] }.to_json)
    stub_request(:get, "https://kong-admin.test/routes").to_return(status: 200, body: { data: [], offset: nil }.to_json)
    post login_connection_path(connection), params: { username: "alice", password: "pw" }
  end

  def cert(name, not_after, type: "certificate", conn: connection, **attrs)
    create(:kong_entity, kong_connection: conn, entity_type: type, name: name, not_after: not_after, **attrs)
  end

  it "redirects to the root path when nobody is signed in" do
    get expiring_certificates_path

    expect(response).to redirect_to(root_path)
  end

  it "lists certificates and CA certificates expiring inside the window, soonest first, expired included" do
    sign_in
    cert("later.example", 20.days.from_now)
    cert("gone.example", 3.days.ago)
    cert("root-ca", 5.days.from_now, type: "ca_certificate")
    cert("far.example", 200.days.from_now)

    get expiring_certificates_path

    body = response.body
    expect(body).to include("gone.example").and include("root-ca").and include("later.example")
    expect(body).not_to include("far.example")
    expect(body.index("gone.example")).to be < body.index("root-ca")
    expect(body.index("root-ca")).to be < body.index("later.example")
    expect(body).to include("Expired").and include("Critical").and include("Warning")
  end

  it "is scoped to the current connection: another connection's certificates never appear" do
    sign_in
    other = create(:kong_connection, name: "prod-other")
    cert("mine.example", 5.days.from_now)
    cert("theirs.example", 5.days.from_now, conn: other)

    get expiring_certificates_path

    expect(response.body).to include("mine.example")
    expect(response.body).not_to include("theirs.example")
  end

  it "leaves out soft-deleted rows, non-certificates, and rows with no expiry" do
    sign_in
    cert("deleted.example", 5.days.from_now, deleted_at: 1.hour.ago)
    create(:kong_entity, kong_connection: connection, entity_type: "service", name: "svc-no-expiry")
    cert("unparsed.example", nil)

    get expiring_certificates_path

    expect(response.body).not_to include("deleted.example")
    expect(response.body).not_to include("svc-no-expiry")
    expect(response.body).not_to include("unparsed.example")
  end

  it "narrows to the requested window, and ignores a nonsense one" do
    sign_in
    cert("soon.example", 5.days.from_now)
    cert("month.example", 20.days.from_now)

    get expiring_certificates_path(days: 7)
    expect(response.body).to include("soon.example")
    expect(response.body).not_to include("month.example")

    get expiring_certificates_path(days: "banana")
    expect(response.body).to include("month.example") # back to 30
    get expiring_certificates_path(days: -5)
    expect(response.body).to include("month.example")
  end

  it "says so when nothing is expiring, and how fresh the data is" do
    sign_in

    get expiring_certificates_path

    expect(response.body).to include("Nothing expires within 30 days")
    expect(response.body).to include("never synced")
  end

  it "links each row to its entity page" do
    sign_in
    certificate = cert("linked.example", 5.days.from_now)

    get expiring_certificates_path

    expect(response.body).to include(entity_path(certificate))
  end

  it "is reachable from the certificates tab" do
    sign_in

    get entities_path(type: "certificate")

    expect(response.body).to include(expiring_certificates_path)
  end
end
```

- [ ] **Step 2: Run to verify it fails**

Run: `bundle exec rspec -r "$K" spec/requests/certificates_spec.rb`
Expected: FAIL — `undefined local variable or method 'expiring_certificates_path'`.

- [ ] **Step 3: Implement**

`config/routes.rb` — after the `resources :plugins` line add:

```ruby
  resources :certificates, only: [] do
    collection { get :expiring }
  end
```

Create `app/controllers/certificates_controller.rb`:

```ruby
# The expiry dashboard (docs/DESIGN.md section 8: "ผลพลอยได้ — dashboard cert
# หมดอายุ"). Scoped to the session's *current connection* on purpose: a web
# session holds one connection's credential and the header shows that
# connection's colour badge, so a cross-connection table would blur the
# environment guardrail DESIGN section 14 calls the cheapest and most
# effective. The estate-wide view is the REST/MCP `kong_certs_expiring`.
#
# Reads the read-model only -- nothing here calls Kong.
class CertificatesController < ApplicationController
  before_action :require_session!

  DEFAULT_DAYS = 30
  MAX_DAYS = 3650
  WINDOWS = [ 7, 30, 90 ].freeze

  def expiring
    @days = normalized_days
    scope = KongEntity.active.where(kong_connection: current_connection, entity_type: %w[certificate ca_certificate])
    @entities = scope.expiring_within(@days).order(:not_after, :id)
    @last_synced_at = scope.maximum(:synced_at)
  end

  private

  def normalized_days
    days = params[:days].to_i
    days.between?(1, MAX_DAYS) ? days : DEFAULT_DAYS
  end
end
```

Create `app/views/certificates/expiring.html.erb`:

```erb
<% content_for :title, "Expiring certificates" %>

<div class="flex flex-wrap items-center justify-between gap-4 mb-4">
  <div>
    <h1 class="text-xl font-semibold" style="color: var(--color-ink)">Expiring certificates</h1>
    <p class="text-sm mt-0.5" style="color: var(--color-ink-soft)">
      Certificates and CA certificates on <%= current_connection.name %> that expire within <%= @days %> days, expired ones included.
      <% if @last_synced_at %>Last synced <%= time_ago_in_words(@last_synced_at) %> ago.<% else %>This connection has never synced.<% end %>
    </p>
  </div>
  <nav class="flex gap-1 text-sm" aria-label="Window">
    <% CertificatesController::WINDOWS.each do |window| %>
      <%= link_to "#{window} days", expiring_certificates_path(days: window),
            class: "px-2.5 py-1 rounded #{'font-semibold' if @days == window}",
            style: @days == window ? "color: var(--color-ink); background: var(--color-surface-subtle)" : "color: var(--color-ink-soft)" %>
    <% end %>
  </nav>
</div>

<% if @entities.empty? %>
  <div class="panel p-6 text-sm text-center" style="color: var(--color-ink-soft)">
    Nothing expires within <%= @days %> days<%= @last_synced_at ? "" : " — this connection has never synced, so nothing is known yet" %>.
  </div>
<% else %>
  <div class="overflow-x-auto panel">
    <table class="w-full text-sm">
      <thead>
        <tr class="text-left"><th class="section-label px-3 py-2">Name</th><th class="section-label px-3 py-2">Kind</th><th class="section-label px-3 py-2">Expires</th><th class="section-label px-3 py-2">On</th></tr>
      </thead>
      <tbody>
        <% @entities.each do |entity| %>
          <tr style="border-top: 1px solid var(--color-border)">
            <td class="px-3 py-2.5 font-semibold"><%= link_to entity.name, entity_path(entity) %></td>
            <td class="px-3 py-2.5" style="color: var(--color-ink-soft)"><%= entity_type_label(entity.entity_type, count: 1) %></td>
            <td class="px-3 py-2.5"><span class="inline-flex flex-wrap items-center gap-1.5"><%= expiry_badge(entity) %> <span class="text-xs" style="color: var(--color-ink-soft)"><%= expiry_when(entity) %></span></span></td>
            <td class="px-3 py-2.5 font-mono text-xs"><%= entity.not_after.to_date %></td>
          </tr>
        <% end %>
      </tbody>
    </table>
  </div>
<% end %>
```

`app/views/entities/index.html.erb` — in the button area, next to the `certificate` "New certificate" link added in Task 9, add an "Expiring soon" link for the two certificate tabs. Change the two branches to:

```erb
    <% elsif @type == "certificate" || @type == "ca_certificate" %>
      <%= link_to "Expiring soon", expiring_certificates_path, class: "btn-secondary px-3.5 py-2 text-sm" %>
      <%= link_to(@type == "certificate" ? "New certificate" : "New CA certificate", new_entity_path(type: @type), class: "btn-primary px-3.5 py-2 text-sm") %>
```

(replacing the two separate `elsif` branches from Task 9 with this single one).

- [ ] **Step 4: Run to verify it passes, then everything**

Run: `bundle exec rspec -r "$K" spec/requests/certificates_spec.rb spec/requests/entities_spec.rb` — PASS. Then `bundle exec rspec -r "$K"` — 0 failures.

- [ ] **Step 5: Normalize line endings and commit**

```bash
sed -i 's/\r$//; s/$/\r/' app/controllers/certificates_controller.rb app/views/certificates/expiring.html.erb spec/requests/certificates_spec.rb
git add app/controllers/certificates_controller.rb app/views/certificates config/routes.rb app/views/entities/index.html.erb spec/requests/certificates_spec.rb
git commit -m "feat(m5b): expiry dashboard for the current connection"
```

---

### Task 12: REST and MCP — `certificates/expiring`, `kong_certs_expiring`, and `acknowledge_env_vars`

**Files:**
- Create: `app/controllers/api/v1/certificates_controller.rb`
- Modify: `config/routes.rb`, `app/controllers/api/v1/change_plans_controller.rb`, `mcp/src/client.ts`, `mcp/src/tools.ts`
- Test: `spec/requests/api/v1/certificates_spec.rb` (create), `spec/requests/api/v1/change_plans_spec.rb` (extend), `mcp/src/client.test.ts`, `mcp/src/tools.test.ts`

**Interfaces:**
- Consumes: `KongEntity.expiring_within`, `#expiry_status` (Task 4); `Kong::ChangeApplier` `env_acknowledged:` (Task 7); `current_pat.kong_connections` (existing).
- Produces:
  - `GET /api/v1/certificates/expiring?days=&connection=` → `{ data: [{connection, type, name, kong_id, snis, not_after, days_left, status}], meta: {days, connections, generated_at} }`, across **every connection the token is bound to** (or the one named; a connection the token is not bound to → 401).
  - `POST /api/v1/change_plans/:id/apply` accepts `acknowledge_env_vars` (boolean).
  - MCP `KongctlClient#certsExpiring({days?, connection?})`, `#applyChange(planId, connection, acknowledgeEnvVars = false)`; MCP tool `kong_certs_expiring`; `kong_apply` gains optional `acknowledge_env_vars`.

- [ ] **Step 1: Write the failing Ruby tests**

Create `spec/requests/api/v1/certificates_spec.rb`:

```ruby
require "rails_helper"

RSpec.describe "API::V1::Certificates", type: :request do
  def auth(raw) = { "Authorization" => "Bearer #{raw}" }

  def token_for(*connections)
    _pat, raw = PersonalAccessToken.issue!(operator: "alice", issued_by_username: "alice", connection_ids: connections.map(&:id))
    raw
  end

  let(:dev) { create(:kong_connection, name: "dev", credential_mode: "stored", auth_secret: "s3cr3t") }
  let(:sit) { create(:kong_connection, name: "sit", rank: 1, credential_mode: "stored", auth_secret: "s3cr3t") }
  let(:prod) { create(:kong_connection, name: "prod", rank: 3, credential_mode: "stored", auth_secret: "s3cr3t") }

  def cert(connection, name, not_after, type: "certificate", **attrs)
    create(:kong_entity, kong_connection: connection, entity_type: type, name: name, not_after: not_after,
      data: { "snis" => [ name ], "_metadata" => { "fingerprint_sha256" => "a" * 64 } }, **attrs)
  end

  it "requires a token" do
    get expiring_api_v1_certificates_path

    expect(response).to have_http_status(:unauthorized)
  end

  it "covers every connection the token is bound to, soonest first, and none it is not" do
    cert(dev, "dev.example", 20.days.from_now)
    cert(sit, "sit.example", 3.days.from_now)
    cert(prod, "prod.example", 1.day.from_now) # not bound to the token

    get expiring_api_v1_certificates_path, headers: auth(token_for(dev, sit))

    expect(response).to have_http_status(:ok)
    json = JSON.parse(response.body)
    expect(json["data"].map { |c| c["name"] }).to eq(%w[sit.example dev.example])
    expect(json["data"].map { |c| c["connection"] }).to eq(%w[sit dev])
    expect(json["meta"]).to include("days" => 30, "connections" => %w[dev sit])
  end

  it "reports type, snis, expiry, days left and status, and never a key or a PEM" do
    cert(dev, "pay.example", 5.days.from_now)
    cert(dev, "root-ca", 2.days.ago, type: "ca_certificate")

    get expiring_api_v1_certificates_path, headers: auth(token_for(dev))

    rows = JSON.parse(response.body)["data"].index_by { |r| r["name"] }
    expect(rows["pay.example"]).to include("type" => "certificate", "snis" => [ "pay.example" ], "status" => "critical")
    expect(rows["pay.example"]["days_left"]).to eq(4) # created an instant ago, so a hair under 5 days, floored
    expect(Time.iso8601(rows["pay.example"]["not_after"])).to be_within(1.minute).of(5.days.from_now)
    expect(rows["root-ca"]).to include("type" => "ca_certificate", "status" => "expired")
    expect(rows["root-ca"]["days_left"]).to be_negative
    expect(response.body).not_to include("PRIVATE KEY")
    expect(rows["pay.example"]["kong_id"]).to be_present
    expect(rows["pay.example"].keys).not_to include("key", "cert", "data")
  end

  it "narrows to one named connection, and refuses one the token isn't bound to" do
    cert(dev, "dev.example", 5.days.from_now)
    cert(sit, "sit.example", 5.days.from_now)
    token = token_for(dev, sit)

    get expiring_api_v1_certificates_path(connection: "sit"), headers: auth(token)
    expect(JSON.parse(response.body)["data"].map { |c| c["name"] }).to eq([ "sit.example" ])

    get expiring_api_v1_certificates_path(connection: "prod"), headers: auth(token)
    expect(response).to have_http_status(:unauthorized)
  end

  it "honours the days window and falls back to 30 for nonsense" do
    cert(dev, "soon.example", 5.days.from_now)
    cert(dev, "month.example", 20.days.from_now)
    token = token_for(dev)

    get expiring_api_v1_certificates_path(days: 7), headers: auth(token)
    expect(JSON.parse(response.body)["data"].map { |c| c["name"] }).to eq([ "soon.example" ])

    get expiring_api_v1_certificates_path(days: "x"), headers: auth(token)
    expect(JSON.parse(response.body)["meta"]["days"]).to eq(30)
  end
end
```

In `spec/requests/api/v1/change_plans_spec.rb` add `require Rails.root.join("spec/support/pem_fixtures")` at the top and insert a `describe` before the final `end` (it reuses the file's `auth` / `token_for` helpers):

```ruby
  describe "certificates and SNIs (M5b)" do
    let(:connection) { create(:kong_connection, admin_url: "https://kong-admin.test", access_level: "rw", credential_mode: "stored", auth_secret: "devpassword") }
    let(:token) { token_for(connection) }
    let(:cert_id) { "dddddddd-0000-0000-0000-00000000000d" }
    let(:fixture) { PemFixtures.self_signed(days: 60) }
    let(:ref) { "{vault://env/cert-pay-key}" }
    let(:ok) { { status: 200, body: { message: "schema validation successful" }.to_json } }

    def plan_cert(attributes)
      post api_v1_change_plans_path, params: { connection: connection.name, type: "certificate", operation: "create", attributes: attributes },
        headers: auth(token), as: :json
    end

    it "proposes a certificate whose key is a vault reference" do
      stub_request(:post, "https://kong-admin.test/schemas/certificates/validate").to_return(ok)

      plan_cert({ cert: fixture[:cert_pem], key: ref, snis: [ "pay.example.internal" ] })

      expect(response).to have_http_status(:created)
      expect(ChangePlan.find(JSON.parse(response.body)["id"]).after["key"]).to eq(ref)
    end

    it "returns 422 -- not 403 -- for a pasted private key, never echoing it, and creates no plan" do
      plan_cert({ cert: fixture[:cert_pem], key: fixture[:key_pem] })

      expect(response).to have_http_status(:unprocessable_entity)
      expect(JSON.parse(response.body)["error"]).to include("{vault://env/")
      expect(response.body).not_to include("PRIVATE KEY")
      expect(ChangePlan.count).to eq(0)
    end

    it "returns 422 for a decK placeholder on a direct-mode connection" do
      plan_cert({ cert: fixture[:cert_pem], key: '${{ env "DECK_CERT_A" }}' })

      expect(response).to have_http_status(:unprocessable_entity)
    end

    it "proposes an SNI under a certificate given as parent_kong_id" do
      stub_request(:post, "https://kong-admin.test/schemas/snis/validate").to_return(ok)

      post api_v1_change_plans_path, params: { connection: connection.name, type: "sni", operation: "create", parent_kong_id: cert_id,
        attributes: { name: "api.example.internal" } }, headers: auth(token), as: :json

      expect(response).to have_http_status(:created)
      expect(ChangePlan.last.after).to eq({ "name" => "api.example.internal", "certificate" => { "id" => cert_id } })
    end

    describe "kong_apply and the env-var acknowledgement" do
      let(:plan) do
        create(:change_plan, kong_connection: connection, actor_kind: "agent", entity_type: "certificate", operation: "create",
          target_kong_id: nil, before: {}, after: { "cert" => fixture[:cert_pem], "key" => ref, "snis" => [ "pay.example.internal" ] },
          diff: { "operation" => "create" }, base_updated_at: nil)
      end

      it "refuses without acknowledge_env_vars, naming the variable, and leaves the plan pending" do
        post apply_api_v1_change_plan_path(plan), params: { connection: connection.name }, headers: auth(token)

        expect(response).to have_http_status(:forbidden)
        expect(JSON.parse(response.body)["error"]).to include("CERT_PAY_KEY")
        expect(plan.reload.status).to eq("pending")
      end

      it "applies with acknowledge_env_vars: true and records the agent's confirmation" do
        stub_request(:post, "https://kong-admin.test/certificates").to_return(status: 201, body: {
          id: cert_id, cert: fixture[:cert_pem], key: ref, snis: [ "pay.example.internal" ], updated_at: 1_700_000_000
        }.to_json)

        post apply_api_v1_change_plan_path(plan), params: { connection: connection.name, acknowledge_env_vars: true },
          headers: auth(token), as: :json

        expect(response).to have_http_status(:ok)
        event = AuditEvent.find(JSON.parse(response.body)["audit_event_id"])
        expect(event.actor_kind).to eq("agent")
        expect(event.context).to eq({ "acknowledged_env_vars" => [ "CERT_PAY_KEY" ] })
      end

      it "does not treat the string \"false\" as an acknowledgement" do
        post apply_api_v1_change_plan_path(plan), params: { connection: connection.name, acknowledge_env_vars: "false" }, headers: auth(token)

        expect(response).to have_http_status(:forbidden)
      end
    end
  end
```

- [ ] **Step 2: Run to verify they fail**

Run: `bundle exec rspec -r "$K" spec/requests/api`
Expected: FAIL — `undefined local variable or method 'expiring_api_v1_certificates_path'`, the acknowledgement is ignored.

- [ ] **Step 3: Implement the Ruby side**

`config/routes.rb` — inside `namespace :v1`, after `resources :connections`:

```ruby
      resources :certificates, only: [] do
        collection { get :expiring }
      end
```

Create `app/controllers/api/v1/certificates_controller.rb`:

```ruby
module Api
  module V1
    # GET /api/v1/certificates/expiring -- the backing endpoint for the
    # `kong_certs_expiring` MCP tool (docs/DESIGN.md section 8/12). Unlike the
    # web dashboard (one session, one connection), this spans every connection
    # the *token* is bound to: an agent asking "what expires soon" means across
    # the estate. Metadata only -- never a key, never a PEM.
    class CertificatesController < BaseController
      DEFAULT_DAYS = 30
      MAX_DAYS = 3650

      def expiring
        connections = scoped_connections
        return unless connections

        days = normalized_days
        entities = KongEntity.active
          .where(kong_connection: connections, entity_type: %w[certificate ca_certificate])
          .expiring_within(days).includes(:kong_connection).order(:not_after, :id)

        render json: {
          data: entities.map { |entity| serialize(entity) },
          meta: { days: days, connections: connections.map(&:name), generated_at: Time.current.iso8601 }
        }
      end

      private

      def scoped_connections
        return current_pat.kong_connections.order(:rank, :name).to_a if params[:connection].blank?

        connection = current_pat.kong_connections.find_by(name: params[:connection])
        return [ connection ] if connection

        render json: { error: "connection #{params[:connection].inspect} must be one this token is bound to" }, status: :unauthorized
        nil
      end

      def normalized_days
        days = params[:days].to_i
        days.between?(1, MAX_DAYS) ? days : DEFAULT_DAYS
      end

      def serialize(entity)
        {
          "connection" => entity.kong_connection.name, "type" => entity.entity_type, "name" => entity.name,
          "kong_id" => entity.kong_id, "snis" => Array(entity.data["snis"]),
          "not_after" => entity.not_after.iso8601, "days_left" => ((entity.not_after - Time.current) / 1.day).floor,
          "status" => entity.expiry_status
        }
      end
    end
  end
end
```

`app/controllers/api/v1/change_plans_controller.rb` — in `apply`, pass the acknowledgement (string `"false"` must not count, hence the cast):

```ruby
        result = Kong::ChangeApplier.new(
          change_plan: plan, client: client_for(plan.kong_connection),
          actor_username: current_pat.issued_by_username, actor_operator: current_pat.operator,
          secret: plan.kong_connection.auth_secret,
          env_acknowledged: ActiveModel::Type::Boolean.new.cast(params[:acknowledge_env_vars]) == true
        ).call
```

Run: `bundle exec rspec -r "$K" spec/requests/api` — expected PASS.

- [ ] **Step 4: Write the failing MCP tests**

In `mcp/src/client.test.ts` add inside `describe("KongctlClient", ...)` (uses the file's `stubFetch` and `config`):

```ts
  it("certsExpiring sends a Bearer-authed GET with days and connection as query params", async () => {
    const fetchMock = stubFetch(200, { data: [], meta: {} });
    const client = new KongctlClient(config);

    await client.certsExpiring({ days: 14, connection: "prod" });

    expect(fetchMock).toHaveBeenCalledWith(
      "http://localhost:3000/api/v1/certificates/expiring?days=14&connection=prod",
      expect.objectContaining({ method: "GET" })
    );
  });

  it("certsExpiring with no arguments sends no query string", async () => {
    const fetchMock = stubFetch(200, { data: [] });

    await new KongctlClient(config).certsExpiring();

    expect(fetchMock.mock.calls[0][0]).toBe("http://localhost:3000/api/v1/certificates/expiring");
  });

  it("applyChange sends acknowledge_env_vars only when it is asked for", async () => {
    const fetchMock = stubFetch(200, { status: "applied" });
    const client = new KongctlClient(config);

    await client.applyChange(1, "dev");
    expect(JSON.parse(fetchMock.mock.calls[0][1].body)).toEqual({ connection: "dev" });

    await client.applyChange(2, "dev", true);
    expect(JSON.parse(fetchMock.mock.calls[1][1].body)).toEqual({ connection: "dev", acknowledge_env_vars: true });
  });
```

In `mcp/src/tools.test.ts` add inside `describe("registerTools", ...)`:

```ts
  describe("kong_certs_expiring", () => {
    it("passes days and connection through to the client", async () => {
      const { server, tools } = fakeServer();
      const certsExpiring = vi.fn().mockResolvedValue({ data: [{ name: "pay.example" }], meta: { days: 14 } });
      registerTools(server, { certsExpiring } as unknown as KongctlClient);

      const result = await tools.get("kong_certs_expiring")!({ days: 14, connection: "prod" });

      expect(certsExpiring).toHaveBeenCalledWith({ days: 14, connection: "prod" });
      expect(result).toEqual({ content: [{ type: "text", text: JSON.stringify({ data: [{ name: "pay.example" }], meta: { days: 14 } }, null, 2) }] });
    });

    it("accepts no arguments at all -- both are optional", () => {
      const { server, configs } = fakeServer();
      registerTools(server, {} as unknown as KongctlClient);

      const schema = z.object(configs.get("kong_certs_expiring")!.inputSchema!);

      expect(() => schema.parse({})).not.toThrow();
      expect(() => schema.parse({ days: 0 })).toThrow(); // must be positive
    });

    it("surfaces an API error as isError with Rails' message", async () => {
      const { server, tools } = fakeServer();
      const certsExpiring = vi.fn().mockRejectedValue(new KongctlApiError(401, "connection \"prod\" must be one this token is bound to"));
      registerTools(server, { certsExpiring } as unknown as KongctlClient);

      const result = (await tools.get("kong_certs_expiring")!({ connection: "prod" })) as { isError: boolean; content: { text: string }[] };

      expect(result.isError).toBe(true);
      expect(result.content[0].text).toContain("bound to");
    });
  });

  describe("kong_apply acknowledge_env_vars", () => {
    it("is declared in the input schema and optional", () => {
      const { server, configs } = fakeServer();
      registerTools(server, {} as unknown as KongctlClient);
      const shape = configs.get("kong_apply")!.inputSchema!;

      expect(z.object(shape).parse({ connection: "dev", plan_id: 1, acknowledge_env_vars: true }).acknowledge_env_vars).toBe(true);
      expect(() => z.object(shape).parse({ connection: "dev", plan_id: 1 })).not.toThrow();
      expect(shape.acknowledge_env_vars?.description).toContain("CERT_");
    });

    it("forwards the flag only when it is true, leaving existing calls unchanged", async () => {
      const { server, tools } = fakeServer();
      const applyChange = vi.fn().mockResolvedValue({ status: "applied" });
      registerTools(server, { applyChange } as unknown as KongctlClient);

      await tools.get("kong_apply")!({ connection: "dev", plan_id: 1 });
      expect(applyChange).toHaveBeenLastCalledWith(1, "dev");

      await tools.get("kong_apply")!({ connection: "dev", plan_id: 2, acknowledge_env_vars: true });
      expect(applyChange).toHaveBeenLastCalledWith(2, "dev", true);
    });
  });
```

Also extend the `kong_plan` `type` description test from M5a so it names the new types: in the existing `it("tells the agent, in the tool description, ...")` add `expect(described).toContain("certificate");`.

- [ ] **Step 5: Run to verify they fail**

Run: `cd mcp && npx vitest run src/client.test.ts src/tools.test.ts`
Expected: FAIL — `client.certsExpiring is not a function`, no `kong_certs_expiring` tool.

- [ ] **Step 6: Implement the MCP side**

`mcp/src/client.ts` — add the params type and methods:

```ts
export interface CertsExpiringParams {
  days?: number;
  connection?: string;
}
```

```ts
  certsExpiring(params: CertsExpiringParams = {}): Promise<unknown> {
    const query = new URLSearchParams();
    if (params.days !== undefined) query.set("days", String(params.days));
    if (params.connection !== undefined) query.set("connection", params.connection);
    const suffix = query.toString();
    return this.request("GET", `/certificates/expiring${suffix ? `?${suffix}` : ""}`);
  }

  applyChange(planId: number, connection: string, acknowledgeEnvVars = false): Promise<unknown> {
    return this.request("POST", `/change_plans/${planId}/apply`, {
      connection,
      ...(acknowledgeEnvVars ? { acknowledge_env_vars: true } : {})
    });
  }
```

(replace the existing two-argument `applyChange`).

`mcp/src/tools.ts`:

1. In the `kong_plan` `type` description change the list to `"... upstream, target, certificate, sni, or ca_certificate"`, and extend the `parent_kong_id` description: `"... the upstream's kong id for a target, the consumer's for a credential, or the certificate's for an SNI. ..."`. Add to the `kong_plan` description: `"A certificate's key must be a {vault://env/NAME} reference -- a private key is never accepted."`
2. Register the new tool after `kong_search`:

```ts
  server.registerTool(
    "kong_certs_expiring",
    {
      title: "List expiring certificates",
      description:
        "Certificates and CA certificates that expire within a window, expired ones included, soonest first, across " +
        "every connection this token can reach (or one, with connection=). Reads the last sync -- check meta.generated_at " +
        "and sync first if it might be stale. Never returns a key or a PEM.",
      inputSchema: {
        days: z.number().int().positive().optional().describe("Window in days (default 30)"),
        connection: z.string().optional().describe("Limit to one connection this token is bound to")
      }
    },
    async (params) => {
      try {
        return ok(await client.certsExpiring(params));
      } catch (error) {
        return fail(error);
      }
    }
  );
```

3. `kong_apply` — extend the schema and the call:

```ts
      inputSchema: {
        connection: z.string(),
        plan_id: z.number().int().describe("The id kong_plan returned"),
        acknowledge_env_vars: z
          .boolean()
          .optional()
          .describe(
            "Required to apply a certificate whose key is a {vault://env/NAME} reference: pass true only after confirming " +
              "the variable (e.g. CERT_PAYMENTS_KEY) is set on every Kong node. Kong won't notice if it is missing."
          )
      }
    },
    async ({ connection, plan_id, acknowledge_env_vars }) => {
      try {
        return ok(
          acknowledge_env_vars
            ? await client.applyChange(plan_id, connection, true)
            : await client.applyChange(plan_id, connection)
        );
      } catch (error) {
        return fail(error);
      }
    }
```

- [ ] **Step 7: Run to verify everything passes**

Run: `cd mcp && npx vitest run && npx tsc --noEmit -p .` — expected: all pass except the one pre-existing `config.test.ts` failure; `tsc` clean.
Run: `bundle exec rspec -r "$K"` — 0 failures.

- [ ] **Step 8: Normalize line endings and commit**

```bash
sed -i 's/\r$//; s/$/\r/' app/controllers/api/v1/certificates_controller.rb spec/requests/api/v1/certificates_spec.rb
(cd mcp && sed -i 's/\r$//; s/$/\r/' src/client.ts src/tools.ts src/client.test.ts src/tools.test.ts)
git add app/controllers/api config/routes.rb spec/requests/api mcp/src
git commit -m "feat(m5b): kong_certs_expiring, and acknowledge_env_vars for agents"
```

---

### Task 13: Live end-to-end check, docs, and final verification

**Files:**
- Create (outside the repo): `<scratchpad>/e2e_m5b.rb`
- Modify: `README.md`, `docs/DESIGN.md`, `docs/DESIGN.html`

**Interfaces:**
- Consumes: everything above, against a **real** temporary Kong 3.7 node.
- Produces: proof that the mechanism works end to end, and a clean repo state.

This is the check that found M5a's millisecond bug. Mocks encode what we already believe; only a real Kong can surprise us. **Do not skip it.**

- [ ] **Step 1: Make a throwaway certificate and start a temporary Kong node**

The node shares the local stack's Postgres (network `kongsole_default`), exposes its Admin API on `8101` and TLS on `8543`, and carries the private key **only** as an environment variable.

```bash
export MSYS_NO_PATHCONV=1
D=$(mktemp -d) && echo "$D" > /tmp/m5b_e2e_dir && cd "$D"
openssl req -x509 -newkey rsa:2048 -nodes -keyout key.pem -out cert.pem -days 60 \
  -subj "/CN=e2e.example.internal" -addext "subjectAltName=DNS:e2e.example.internal"
docker rm -f m5b-e2e-kong >/dev/null 2>&1
docker run -d --name m5b-e2e-kong --network kongsole_default \
  -e KONG_DATABASE=postgres -e KONG_PG_HOST=kong-database -e KONG_PG_USER=kong -e KONG_PG_PASSWORD=kong -e KONG_PG_DATABASE=kong \
  -e KONG_ADMIN_LISTEN=0.0.0.0:8001 -e "KONG_PROXY_LISTEN=0.0.0.0:8000, 0.0.0.0:8443 ssl" \
  -e "CERT_E2E_KEY=$(cat key.pem)" -p 8101:8001 -p 8543:8443 kong:3.7
for i in $(seq 1 30); do [ "$(curl -s -o /dev/null -w '%{http_code}' http://localhost:8101/)" = 200 ] && echo "up" && break; sleep 1; done
```

Expected: `up`. Confirm the stack is empty first: `curl -s http://localhost:8101/certificates` → `"data":[]`.

- [ ] **Step 2: Write the end-to-end script**

Write `<scratchpad>/e2e_m5b.rb` with the Write tool (not a heredoc). It runs inside a transaction that is rolled back and removes everything it created from Kong in `ensure`.

```ruby
# M5b end to end, against the temporary Kong node on :8101 (TLS on :8543).
require "net/http"
require "socket"
require "openssl"

dir = ENV.fetch("M5B_E2E_DIR")
cert_pem = File.read(File.join(dir, "cert.pem"))
key_pem = File.read(File.join(dir, "key.pem"))
expected_fp = OpenSSL::Digest::SHA256.hexdigest(OpenSSL::X509::Certificate.new(cert_pem).to_der)

results = []
check = lambda do |label, ok, detail = nil|
  results << [ label, ok ]
  puts format("%-4s %s%s", ok ? "PASS" : "FAIL", label, detail ? "  -- #{detail}" : "")
end

admin = lambda do |verb, path|
  req = Net::HTTP.const_get(verb.to_s.capitalize).new(path)
  res = Net::HTTP.start("localhost", 8101) { |http| http.request(req) }
  [ res.code.to_i, (JSON.parse(res.body) rescue nil) ]
end

# What the proxy serves for an SNI -- the fingerprint, or the error class.
served = lambda do |host|
  tcp = TCPSocket.new("localhost", 8543)
  ctx = OpenSSL::SSL::SSLContext.new
  ctx.verify_mode = OpenSSL::SSL::VERIFY_NONE
  ssl = OpenSSL::SSL::SSLSocket.new(tcp, ctx)
  ssl.hostname = host
  ssl.connect
  OpenSSL::Digest::SHA256.hexdigest(ssl.peer_cert.to_der)
rescue OpenSSL::SSL::SSLError, SystemCallError => e
  "error: #{e.class}"
ensure
  ssl&.close
  tcp&.close
end

ActiveRecord::Base.transaction do
  connection = KongConnection.create!(
    name: "m5b-e2e", env: "dev", rank: 0, admin_url: "http://localhost:8101", auth_type: "basic", auth_username: "e2e",
    credential_mode: "session", apply_mode: "direct", access_level: "rw", writable: true
  )
  client = Kong::Client.new(connection: connection, secret: nil)
  plan = ->(**args) { Kong::ChangePlanner.new(connection: connection, client: client, actor_username: "e2e", **args).call }
  apply = ->(p, **kw) { Kong::ChangeApplier.new(change_plan: p, client: client, actor_username: "e2e", **kw).call }

  begin
    check.call("temporary node starts with no certificates", admin.call(:get, "/certificates")[1]["data"].empty?)

    # 1. the policy, against a real Kong: nothing reaches it
    begin
      plan.call(operation: "create", entity_type: "certificate", attributes: { "cert" => cert_pem, "key" => key_pem })
      check.call("a PEM key is rejected", false, "no error raised")
    rescue Kong::CertificateKeyPolicy::Rejected => e
      check.call("a PEM key is rejected at plan time, without echoing it", !e.message.include?("PRIVATE KEY"), e.message[0, 70])
    end
    begin
      plan.call(operation: "create", entity_type: "certificate", attributes: { "cert" => cert_pem, "key" => '${{ env "DECK_E2E" }}' })
      check.call("a decK placeholder is rejected in direct mode", false, "no error raised")
    rescue Kong::CertificateKeyPolicy::Rejected
      check.call("a decK placeholder is rejected in direct mode", true)
    end
    check.call("no plan or request resulted from the rejections", ChangePlan.count.zero? && admin.call(:get, "/certificates")[1]["data"].empty?)

    # 2. create with a vault reference; real Kong validates the body
    ref = "{vault://env/cert-e2e-key}"
    c_plan = plan.call(operation: "create", entity_type: "certificate",
      attributes: { "cert" => cert_pem, "key" => ref, "snis" => [ "e2e.example.internal" ], "tags" => [ "m5b-e2e" ] })
    check.call("certificate plan validated by Kong", c_plan.persisted? && c_plan.after["key"] == ref)
    check.call("the review would ask for CERT_E2E_KEY", Kong::CertificateKeyPolicy.env_vars_for(c_plan) == [ "CERT_E2E_KEY" ])

    begin
      apply.call(c_plan)
      check.call("apply refused without the acknowledgement", false, "applied anyway")
    rescue Kong::ChangeGuardrails::Violation => e
      check.call("apply refused without the acknowledgement, naming the variable", e.message.include?("CERT_E2E_KEY") && c_plan.reload.status == "pending")
    end

    result = apply.call(c_plan, env_acknowledged: true)
    check.call("applied with the acknowledgement; audit records it", result.audit_event.context == { "acknowledged_env_vars" => [ "CERT_E2E_KEY" ] })
    code, live = admin.call(:get, "/certificates?tags=m5b-e2e")
    cert = live["data"].first
    check.call("Kong stores and returns the reference verbatim", code == 200 && cert["key"] == ref)

    # 3. the read-model: metadata, never the PEM or a key
    row = KongEntity.find_by!(kong_connection: connection, entity_type: "certificate")
    check.call("read-model named by first SNI, keyed by the SNI set", row.name == "e2e.example.internal" && row.logical_key == "e2e.example.internal")
    check.call("metadata fingerprint matches the real certificate", row.data.dig("_metadata", "fingerprint_sha256") == expected_fp)
    check.call("not_after is ~60 days out and the status is ok", row.not_after.between?(59.days.from_now, 61.days.from_now) && row.expiry_status == "ok")
    check.call("the PEM is not cached", !row.data.key?("cert") && !row.data.to_json.include?("BEGIN CERTIFICATE"))
    everything = [ KongEntity, ChangePlan, AuditEvent ].flat_map { |m| m.all.map(&:to_json) }.join
    check.call("no private key anywhere in the tool's database", !everything.include?("PRIVATE KEY") && !everything.include?(key_pem.lines[1].strip))

    # 4. an SNI, and the parent's derived name following it
    s_plan = plan.call(operation: "create", entity_type: "sni", parent_kong_id: cert["id"], attributes: { "name" => "a.e2e.example.internal" })
    check.call("SNI body carries its certificate", s_plan.after["certificate"] == { "id" => cert["id"] })
    apply.call(s_plan)
    check.call("SNI exists in Kong", admin.call(:get, "/snis/a.e2e.example.internal")[0] == 200)
    check.call("parent certificate re-synced: now named by the first sorted SNI",
      KongEntity.find_by!(kong_id: cert["id"]).name == "a.e2e.example.internal")

    # 5. the proof: real TLS, real environment variable
    sleep 6
    fp = served.call("e2e.example.internal")
    check.call("the proxy serves OUR certificate -- the env var resolved", fp == expected_fp, fp[0, 24])

    # 6. the limitation, demonstrated honestly: a typo'd reference is accepted and TLS then fails
    t_plan = plan.call(operation: "create", entity_type: "certificate",
      attributes: { "cert" => cert_pem, "key" => "{vault://env/cert-typo-key}", "snis" => [ "typo.example.internal" ], "tags" => [ "m5b-e2e" ] })
    apply.call(t_plan, env_acknowledged: true)
    sleep 6
    check.call("Kong accepted the typo'd reference (it cannot tell), and TLS for that host now fails",
      served.call("typo.example.internal").start_with?("error"), served.call("typo.example.internal"))

    # 7. sync from scratch reproduces the same picture
    KongEntity.where(kong_connection: connection).delete_all
    Kong::EntitySync.sync_connection(connection: connection, client: client)
    types = KongEntity.active.where(kong_connection: connection).pluck(:entity_type)
    check.call("a fresh sync finds 2 certificates and 2 SNIs", types.count("certificate") == 2 && types.count("sni") == 2)
    check.call("expiring_within(90) finds them", KongEntity.expiring_within(90).where(kong_connection: connection, entity_type: "certificate").count == 2)

    # 8. edits: tags need no acknowledgement; delete cascades the read-model
    good = KongEntity.active.find_by!(kong_connection: connection, entity_type: "certificate", name: "a.e2e.example.internal")
    e_plan = plan.call(operation: "update", entity_type: "certificate", target_kong_id: good.kong_id, attributes: { "tags" => [ "m5b-e2e", "edited" ] })
    check.call("a tags-only edit needs no acknowledgement", Kong::CertificateKeyPolicy.env_vars_for(e_plan).empty?)
    apply.call(e_plan)
    check.call("tags changed in Kong", admin.call(:get, "/certificates/#{good.kong_id}")[1]["tags"].include?("edited"))

    d_plan = plan.call(operation: "delete", entity_type: "certificate", target_kong_id: good.kong_id)
    apply.call(d_plan)
    check.call("deleted certificate takes its SNIs out of the read-model too",
      KongEntity.active.where(kong_connection: connection, parent_kong_id: good.kong_id).none?)
    check.call("...and Kong removed them", admin.call(:get, "/snis/a.e2e.example.internal")[0] == 404)

    # 9. a CA certificate
    ca_plan = plan.call(operation: "create", entity_type: "ca_certificate", attributes: { "cert" => cert_pem, "tags" => [ "m5b-e2e" ] })
    apply.call(ca_plan)
    ca = KongEntity.find_by!(kong_connection: connection, entity_type: "ca_certificate")
    check.call("CA certificate synced with metadata and expiry", ca.not_after.present? && ca.data.dig("_metadata", "fingerprint_sha256") == expected_fp)
  ensure
    %w[snis certificates ca_certificates].each do |kind|
      Array(admin.call(:get, "/#{kind}")[1]&.dig("data")).each { |x| admin.call(:delete, "/#{kind}/#{x['id']}") }
    end
  end

  raise ActiveRecord::Rollback
end

failed = results.reject(&:last)
puts "\n#{results.size - failed.size}/#{results.size} checks passed"
exit(failed.empty? ? 0 : 1)
```

- [ ] **Step 3: Run it**

```bash
cd /d/kongsole
export DATABASE_URL="postgres://kongsole:kongsole@localhost:5433/kong_integration_test" RAILS_ENV=test
M5B_E2E_DIR="$(cat /tmp/m5b_e2e_dir)" bin/rails runner "<scratchpad>/e2e_m5b.rb" 2>&1 | grep -vE "warning: |fiddle|^$"
```

Expected: every line `PASS`, ending `N/N checks passed`. **Any FAIL is a real finding** — reproduce it as a failing spec first, fix it, and re-run; do not weaken the script. The typo'd-reference check passing means Kong really does accept a wrong reference and TLS really does fail — that is the documented limitation the acknowledgement exists for.

- [ ] **Step 4: Tear the node down and prove the stack is clean**

```bash
docker rm -f m5b-e2e-kong
rm -rf "$(cat /tmp/m5b_e2e_dir)" /tmp/m5b_e2e_dir
for kind in snis certificates ca_certificates upstreams; do printf "%-16s " $kind; curl -s "http://localhost:8001/$kind" | python -c "import sys,json; print(len(json.load(sys.stdin)['data']), 'left')"; done
docker ps -a --format '{{.Names}}' | grep -c m5b-e2e || echo "e2e container: gone"
```

Expected: `0 left` for all four and `e2e container: gone`. If anything remains, delete it through the Admin API and note that the script's `ensure` did not fire.

- [ ] **Step 5: Documentation**

`README.md` — add a section after "Upstreams and targets (M5a)":

```markdown
## Certificates, SNIs and CA certificates (M5b)

`certificate`, `sni` and `ca_certificate` are managed like every other type, in direct mode
(`docs/DESIGN.md` section 8; design and Kong 3.7 findings in
`docs/superpowers/specs/2026-09-21-m5b-certificates-snis-design.md`).

- **A private key is never accepted.** A certificate's `key` is a reference:
  `{vault://env/cert-payments-key}` makes Kong read `CERT_PAYMENTS_KEY` from its own
  environment, so the key is in neither git nor Kong's database. A pasted PEM is rejected
  with an error (never silently dropped); the API answers 422. In PR mode a decK
  placeholder `${{ env "DECK_CERT_PAYMENTS_KEY" }}` is also accepted (rendering is M5c).
- **Kong does not validate a vault reference**, and a missing variable makes TLS for that
  hostname fail. So applying a certificate whose key reference is new or changed requires
  confirming the variable exists on every Kong node (a checkbox on the review page,
  `acknowledge_env_vars` for `kong_apply`); the confirmation is recorded in the audit event.
- The read-model caches certificate **metadata** (subject, issuer, expiry, fingerprint,
  SANs), not the PEM. **Certificates → Expiring soon** lists what expires within 7/30/90
  days on the current connection; the MCP tool `kong_certs_expiring` covers every connection
  the token can reach.
- Run `bin/rails db:migrate` — M5b adds `audit_events.context`.
```

`docs/DESIGN.md` — in section 8 ("Certificate และความลับ"), after the paragraph beginning `**ผลพลอยได้:**`, add:

```markdown
**ผลการ spike (M5b, Kong 3.7.1):** `{vault://env/cert-x-key}` อ่านตัวแปร `CERT_X_KEY` (ตัวพิมพ์ใหญ่, `-` → `_`) และ Kong เก็บ/คืนค่า reference ตามที่ส่งมา ไม่เคยคืน PEM · **Kong ไม่ตรวจ reference ตอนเขียน** — ตัวแปรที่ไม่มีอยู่หรือ key ที่ไม่ตรงกับ cert ก็ได้ 201 และ TLS ของ hostname นั้นจะล้ม (`tlsv1 alert internal error`) ตอนใช้งานจริง → tool จึงบังคับให้ยืนยันว่าตัวแปรมีอยู่ก่อน apply และบันทึกลง audit · tool ไม่รับ private key ในรูป PEM ทุกช่องทาง
```

Add the equivalent short paragraph to `docs/DESIGN.html` inside the matching section 8 block (find the paragraph containing `dashboard cert หมดอายุ` or `kong_certs_expiring` and append a sibling `<p class="col" ...>` with the same text, using `<code>` for identifiers).

- [ ] **Step 6: Final verification — evidence before claims**

```bash
export DATABASE_URL="postgres://kongsole:kongsole@localhost:5433/kong_integration_test"
K="C:/Users/66880/AppData/Local/Temp/claude/d--kongsole/06b4608a-a6d3-494b-8684-2c796edce238/scratchpad/test_encryption_keys.rb"
bundle exec rspec -r "$K" 2>&1 | grep -E "^rspec|examples,"      # expect 0 failures
bundle exec rspec 2>&1 | grep -E "Missing Active Record" | sort | uniq -c   # as-is: only that environment error
bundle exec rubocop 2>&1 | grep -E "inspected"                     # expect no offenses
bundle exec brakeman -q --no-pager 2>&1 | grep -E "Security Warnings"   # expect 0
(cd mcp && npx vitest run 2>&1 | grep -E "Tests |×" ; npx tsc --noEmit -p . && echo "tsc OK")
git status --short | grep -v node_modules
```

Expected: 0 failures with keys supplied; the as-is failures are **only** `Missing Active Record encryption credential`; RuboCop clean; Brakeman `0`; MCP shows only the pre-existing `config.test.ts` failure; `tsc OK`. Confirm `git status` lists no `.pem`, `.key` or scratch files.

Then report honestly: what passed, what the environment prevents (the encryption keys), the pre-existing `config.ts` hardcoded token (untouched), and that PR-mode rendering of these types is M5c.

- [ ] **Step 7: Commit**

```bash
git add README.md docs/DESIGN.md docs/DESIGN.html
git commit -m "docs(m5b): certificates, SNIs and the key-on-env policy"
```

