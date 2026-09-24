# R7 — Export config Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** export decK YAML ของ connection ที่ login อยู่ด้วย `deck gateway dump --select-tag <ค่าที่ผู้ใช้กรอก>` → ผ่าน `Kong::ExportSanitizer` เสมอ (ตัด credential, private key, secret ของ plugin, entity admin path) → preview → ดาวน์โหลด; `kong_export` ของ MCP ใช้ทางเดียวกัน

**Architecture:** `Kong::DeckCli#dump` คืน YAML เป็น String ในหน่วยความจำ (`-o -`, ไม่เขียนดิสก์) → `Kong::ExportSanitizer` (pure: รับ text + ข้อมูลของ connection, คืน `Result(yaml, summary, removed)`) → serialize แบบ deterministic → ส่งด้วย `send_data` · บันทึก `AuditEvent(operation: "export")` เก็บแค่ tags + sha256 ไม่เก็บเนื้อไฟล์

**Tech Stack:** decK CLI 1.51.1/1.66.1, Rails 8.1, TypeScript MCP, RSpec + vitest

**Spec:** `docs/requirements/R7-export-config.md` (+ `design-amendments.md` §C8, §A3, **§B**), `docs/plans/00-roadmap.md` (Q24, F2, F3)

## Global Constraints

- **Gate:** เริ่ม R7.1 ได้เมื่อ CLAUDE.md กฎข้อ 2 ถูกแก้ตาม `design-amendments.md` §B แล้วเท่านั้น
- ต้องมี select_tag ≥ 1 ค่า, ห้าม `kong-admin-path`, แต่ละค่า match `/\A[A-Za-z0-9._~:-]{1,128}\z/`
- output ของ dump ห้ามเขียนลงดิสก์ ห้าม log ห้ามเก็บใน DB ก่อน/หลัง sanitize (AuditEvent เก็บ sha256 เท่านั้น)
- ผลลัพธ์ห้ามมี: `*_credentials`, `jwt_secrets`, `oauth2_credentials`, private key ของ certificate (ยกเว้น vault reference), ค่าลับของ plugin (ยกเว้น reference), entity ที่ tag `kong-admin-path` หรือ `is_admin_path` ใน read-model
- ค่าที่ถูกแทน → decK env placeholder แบบ double-quote `"${{ env "DECK_…" }}"` (รูปแบบที่ใช้ได้จริงตาม M5c)
- `_info.select_tags` = tags ที่ผู้ใช้กรอก (เรียงตามที่กรอก) เสมอ
- body ไม่มีเวลา → export ซ้ำจาก Kong สถานะเดิมได้ไฟล์เหมือนเดิมทุก byte (เวลาอยู่ในชื่อไฟล์)
- credential ของ Kong ส่งให้ decK ผ่าน `--headers` แบบเดียวกับ `DeckCli#diff` เดิม ห้ามอยู่ใน error message

## Review Focus

1. dump มี consumer ที่ tag ตรงแต่เป็น admin path consumer (ถือ credential ของ admin route) → ถูกตัดทั้ง consumer — test ใน R7.2
2. plugin custom ที่ schema อ่านไม่ได้ → secret-looking field กลายเป็น placeholder (fail-closed) — test ใน R7.2
3. certificate ที่ `key` ใน Kong เป็น PEM จริง (ทาง ข ของ DESIGN §8) → placeholder `DECK_CERT_<…>_KEY` ไม่ใช่ PEM — test ใน R7.2
4. decK ไม่ได้ติดตั้ง / `DECK_BIN` ผิด → ข้อความบอกวิธีแก้ ไม่ใช่ 500 — test ใน R7.1
5. tags ที่ไม่มี entity ใดตรง → ไฟล์ว่างที่มี `_info` + คำเตือน "matched nothing" (เพราะ sync ไฟล์นี้จะลบทุกอย่างใต้ tag นั้นที่ปลายทาง) — test ใน R7.2

---

## Spec ที่ตกลงแล้ว

- **ขอบเขต:** connection ที่ login อยู่ (เลือก project/env ผ่าน switcher ของ R1) + select_tags
- **Header ของไฟล์** (comment บรรทัดแรกๆ):
  ```yaml
  # Exported by Kongsole from <project>/<env> with select_tags [<tags>].
  # A snapshot of Kong, not a source of truth. It holds EVERYTHING Kong tags with
  # these select_tags, so `deck gateway sync` against another env deletes whatever
  # that env has under these tags and this file lacks.
  # Secrets are replaced by "${{ env "DECK_..." }}" placeholders: set them before syncing.
  # A PR-mode env must receive this through a PR to its project repo, never a manual sync.
  ```
- **Preview:** YAML (มีเลขบรรทัด), สรุปจำนวนต่อชนิด, รายการที่ถูกตัดหรือแทน (ชนิด, ชื่อ, เหตุผล: `admin_path` / `credential` / `private_key` / `plugin_secret`), รายชื่อ env var placeholder ที่ต้องตั้ง
- **ไฟล์:** `<project>-<env>-<tags joined by +>-<YYYYMMDD-HHMM>.yaml`, `Content-Type: application/yaml`
- **MCP `kong_export`:** `connection` (project/env, บังคับ), `select_tags` (array, บังคับ ≥1) → `{ yaml, summary, removed, env_placeholders }`

## Contract UI ↔ backend

| backend ให้ | รายละเอียด |
|---|---|
| routes | `resource :export, only: %i[new create] do post :preview end` · API `get "api/v1/exports"` |
| `@select_tags_default` | `current_connection.select_tags` |
| `@result` (preview) | `Kong::ExportSanitizer::Result(yaml:, summary: Hash<String,Integer>, removed: [{type:, name:, reason:}], env_placeholders: [String], matched_nothing: Boolean)` |
| `@export_errors` | `{ select_tags: [msg] }` |
| create | `send_data result.yaml, filename:, type: "application/yaml"` |
| error decK/Kong | `flash.now[:alert]` + `flash.now[:error_explanation]` (R3.2) |

---

### Task R7.0: gate — CLAUDE.md กฎข้อ 2

- [ ] ตรวจว่า T0.0 แก้ `CLAUDE.md` ตาม `design-amendments.md` §B แล้ว (เจ้าของงานอนุมัติข้อความเมื่อ 2026-09-24) — ถ้ายังไม่แก้ หยุดถาม

---

### Task R7.1: `DeckCli#dump` (backend)

**ชั้น:** backend · **ต้องเสร็จก่อน:** R7.0, R1, R3.2 · **ไฟล์ที่แก้ได้:** `app/services/kong/deck_cli.rb`, `spec/services/kong/deck_cli_spec.rb`, `app/services/kong/error_explanation.rb`, `spec/services/kong/error_explanation_spec.rb`

**Interfaces:** `Kong::DeckCli.dump(connection:, secret:, select_tags:) -> String` (YAML text); raise `Kong::DeckCli::Error` (ข้อความไม่มี header/credential)

- [ ] **Step 1: spike (อ่านอย่างเดียว, compose rank 0):** ติดตั้ง decK 1.51.1 และ 1.66.1 → รัน `deck gateway dump --select-tag managed-by-kongctl -o - --kong-addr http://kong-admin-ro.internal:8000 --headers "Authorization:Basic …"` → บันทึกใน commit message: stdout เป็น YAML ไหม, มี `_info.select_tags` ไหม, ลำดับ key คงที่ไหม (dump 2 ครั้งเทียบ sha256), dump ใส่ consumer credentials ไหม, `--yes` จำเป็นไหม
- [ ] **Step 2: test**

```ruby
describe ".dump" do
  let(:connection) { create(:kong_connection, admin_url: "http://kong-admin-ro.internal:8000", auth_username: "ro-kongctl") }

  it "dumps to stdout with each select tag and the read-only credential, never to a file" do
    status = instance_double(Process::Status, success?: true)
    expect(Open3).to receive(:capture3) do |env, *argv, **_opts|
      expect(argv).to include("gateway", "dump", "-o", "-", "--select-tag", "managed-by-kongctl", "--select-tag", "team-a")
      expect(argv.join(" ")).not_to match(/--output-file\s+[^-]/)
      [ "_format_version: \"3.0\"\n", "", status ]
    end
    expect(described_class.dump(connection: connection, secret: "pw", select_tags: %w[managed-by-kongctl team-a]))
      .to start_with("_format_version")
  end

  it "never puts the credential into its error message" do
    status = instance_double(Process::Status, success?: false)
    allow(Open3).to receive(:capture3).and_return([ "", "Error: Authorization:Basic cm8ta29uZ2N0bDpwdw== rejected", status ])
    expect { described_class.dump(connection: connection, secret: "pw", select_tags: %w[a]) }
      .to raise_error(Kong::DeckCli::Error) { |e| expect(e.message).not_to include("cm8ta29uZ2N0bDpwdw==") }
  end

  it "names the network problem when this project's Kong is out of reach" do
    status = instance_double(Process::Status, success?: false)
    allow(Open3).to receive(:capture3).and_return([ "", "Error: dial tcp: lookup kong-a-uat.internal: no such host", status ])
    expect { described_class.dump(connection: connection, secret: "pw", select_tags: %w[a]) }
      .to raise_error(Kong::DeckCli::Unreachable) { |e| expect(e.kind).to eq(:dns) }
    expect(Kong::ErrorExplanation.for(Kong::DeckCli::Unreachable.new("x", kind: :dns)).key).to eq("network_dns_failed")
  end

  it "explains a missing decK binary" do
    allow(Open3).to receive(:capture3).and_raise(Errno::ENOENT)
    expect { described_class.dump(connection: connection, secret: "pw", select_tags: %w[a]) }
      .to raise_error(Kong::DeckCli::Error, /decK is not installed.*DECK_BIN/)
  end
end
```

- [ ] **Step 3:** FAIL → implement (ใช้ `run`/`clean` เดิม; `clean` ต้อง scrub `Basic [A-Za-z0-9+/=]+`; `Kong::DeckCli::Unreachable < Error` ที่มี `kind` จาก `Kong::NetworkFailure.classify_text(stderr)` — ใช้กับ `diff` ของ R8 ด้วย; เพิ่ม mapping `DeckCli::Unreachable` → `network_*` ใน `ErrorExplanation`) → PASS
- [ ] **Step 4:** Commit `feat(R7.1): deck gateway dump by select tags, kept in memory`

---

### Task R7.2: `Kong::ExportSanitizer` (backend)

**ชั้น:** backend · **ต้องเสร็จก่อน:** R7.1, R4.1 · **ไฟล์ที่แก้ได้:** Create `app/services/kong/export_sanitizer.rb`, `spec/services/kong/export_sanitizer_spec.rb`, `spec/fixtures/deck/export_with_secrets.yaml`

**Interfaces:** `Kong::ExportSanitizer.call(text, connection:, select_tags:, secret_paths_for: ->(plugin_name) { Array | nil }) -> Result`; raise `Kong::ExportSanitizer::Refused` สำหรับ tags ที่ไม่ผ่านกฎ

- [ ] **Step 1: fixture** `spec/fixtures/deck/export_with_secrets.yaml` — มีครบ: service ปกติ + route + plugin rate-limiting; service `admin-api` tag `kong-admin-path` + route + basic-auth plugin; consumer `jakkapat` ที่ read-model มี `is_admin_path` พร้อม `basicauth_credentials` + `acls`; consumer `partner-x` พร้อม `keyauth_credentials`, `jwt_secrets`, `hmacauth_credentials`; certificate ที่ `key` เป็น PEM (`-----BEGIN PRIVATE KEY-----`); certificate ที่ `key: "{vault://env/cert-a-key}"`; plugin aws-lambda `config.aws_secret: s3cr3t`; plugin custom `team-auth` `config.signing_secret: xyz`
- [ ] **Step 2: test**

```ruby
require "rails_helper"

RSpec.describe Kong::ExportSanitizer do
  let(:connection) { create(:kong_connection) }
  let(:text) { File.read(Rails.root.join("spec/fixtures/deck/export_with_secrets.yaml")) }
  let(:secret_paths) { ->(name) { name == "aws-lambda" ? [ %w[config aws_secret] ] : nil } }

  before do
    create(:kong_entity, kong_connection: connection, entity_type: "consumer", name: "jakkapat", is_admin_path: true)
  end

  def run(tags = %w[managed-by-kongctl]) = described_class.call(text, connection: connection, select_tags: tags, secret_paths_for: secret_paths)

  it "leaves no credential, private key or plugin secret in the file" do
    yaml = run.yaml
    %w[basicauth_credentials keyauth_credentials jwt_secrets hmacauth_credentials BEGIN\ PRIVATE\ KEY s3cr3t xyz].each do |needle|
      expect(yaml).not_to include(needle)
    end
  end

  it "drops admin-path entities by tag and by the read-model" do
    result = run
    expect(result.yaml).not_to include("admin-api", "jakkapat")
    expect(result.removed).to include(include(type: "service", name: "admin-api", reason: :admin_path),
      include(type: "consumer", name: "jakkapat", reason: :admin_path))
  end

  it "replaces secrets with decK env placeholders and lists them" do
    result = run
    expect(result.yaml).to include('"${{ env "DECK_PLUGIN_AWS_LAMBDA_AWS_SECRET" }}"')
    expect(result.yaml).to include("{vault://env/cert-a-key}")
    expect(result.env_placeholders).to include("DECK_PLUGIN_AWS_LAMBDA_AWS_SECRET")
  end

  it "fails closed on a plugin whose schema is unknown" do
    expect(run.yaml).to include('"${{ env "DECK_PLUGIN_TEAM_AUTH_SIGNING_SECRET" }}"')
  end

  it "always writes _info.select_tags and the snapshot header" do
    yaml = run(%w[managed-by-kongctl team-a]).yaml
    expect(yaml).to start_with("# Exported by Kongsole")
    expect(YAML.safe_load(yaml).dig("_info", "select_tags")).to eq(%w[managed-by-kongctl team-a])
  end

  it "is byte-for-byte stable for the same input" do
    expect(run.yaml).to eq(run.yaml)
  end

  it "refuses no tags, the admin-path tag, or a malformed tag" do
    [ [], %w[kong-admin-path], [ "bad tag" ] ].each do |tags|
      expect { run(tags) }.to raise_error(described_class::Refused)
    end
  end

  it "flags an export that matched nothing" do
    result = described_class.call("_format_version: \"3.0\"\n", connection: connection, select_tags: %w[x], secret_paths_for: secret_paths)
    expect(result.matched_nothing).to be(true)
  end
end
```

- [ ] **Step 3:** FAIL → implement (walk ทุก collection และ nested: services/routes/plugins, consumers, upstreams/targets, certificates/snis, ca_certificates, และ top-level plugins; ชื่อ placeholder = `DECK_` + upcase ของส่วนประกอบ แทนอักขระอื่นด้วย `_`; serialize: ลองใช้ `Kong::DeckDocument.serialize(Kong::DeckDocument.parse(text, select_tags:))` ถ้า parse รับได้ ไม่งั้น `Psych` ที่ deep-sort key — บันทึกทางที่ใช้ใน commit) → PASS
- [ ] **Step 4:** Commit `feat(R7.2): export sanitizer strips credentials, keys, plugin secrets and the admin path`

---

### Task R7.3: หน้า export + audit (backend)

**ชั้น:** backend · **ต้องเสร็จก่อน:** R7.2 · **ไฟล์ที่แก้ได้:** Create `app/controllers/exports_controller.rb`, `app/services/kong/config_export.rb` (orchestrate dump → sanitize → audit), `app/views/exports/new.html.erb`, `app/views/exports/preview.html.erb` (ขั้นต่ำ), `spec/requests/exports_spec.rb`, `spec/services/kong/config_export_spec.rb`; Modify `config/routes.rb`

**Interfaces:** `Kong::ConfigExport.call(connection:, secret:, select_tags:, actor_username:, actor_operator:, actor_kind: "human") -> Result` (บันทึก `AuditEvent(operation: "export", entity_type: "config", context: { "select_tags" => tags, "sha256" => digest, "bytes" => size })`)

- [ ] **Step 1: test**

```ruby
# spec/requests/exports_spec.rb
require "rails_helper"

RSpec.describe "Export", type: :request do
  include SignInHelper
  let(:connection) { create(:kong_connection, admin_url: "https://kong.test", project_env: create(:project_env, select_tags: %w[managed-by-kongctl])) }
  let(:dump) { File.read(Rails.root.join("spec/fixtures/deck/export_with_secrets.yaml")) }

  before do
    sign_in_to(connection, access: :ro)
    allow(Kong::DeckCli).to receive(:dump).and_return(dump)
    allow(Kong::SchemaCache).to receive(:fetch).and_return(nil)
  end

  it "previews the sanitized file without storing it" do
    post preview_export_path, params: { select_tags: "managed-by-kongctl" }
    expect(response.body).to include("_info")
    expect(response.body).not_to include("BEGIN PRIVATE KEY")
    expect(Dir.glob(Rails.root.join("tmp/**/*.yaml")).select { File.mtime(_1) > 1.minute.ago }).to be_empty
  end

  it "downloads the same bytes as the preview and records who exported, without the content" do
    post export_path, params: { select_tags: "managed-by-kongctl" }
    expect(response.headers["Content-Disposition"]).to match(/attachment; filename=".+-managed-by-kongctl-\d{8}-\d{4}\.yaml"/)
    event = AuditEvent.last
    expect(event).to have_attributes(operation: "export", entity_type: "config")
    expect(event.context["sha256"]).to eq(Digest::SHA256.hexdigest(response.body))
    expect(event.context.to_json).not_to include("service")
  end

  it "refuses the admin-path tag" do
    post preview_export_path, params: { select_tags: "kong-admin-path" }
    expect(response).to have_http_status(:unprocessable_entity)
    expect(Kong::DeckCli).not_to have_received(:dump)
  end
end
```

- [ ] **Step 2:** FAIL → implement → PASS · suite 0 failures · Commit `feat(R7.3): export page -- preview, download, audited by digest`

---

### Task R7.4: API + MCP `kong_export` (backend)

**ชั้น:** backend · **ต้องเสร็จก่อน:** R7.3 · **ไฟล์ที่แก้ได้:** Create `app/controllers/api/v1/exports_controller.rb`, `spec/requests/api/v1/exports_spec.rb`; Modify `config/routes.rb`, `mcp/src/client.ts`, `mcp/src/tools.ts`, `mcp/src/tools.test.ts`, `mcp/src/client.test.ts`, `mcp/README.md`

- [ ] **Step 1: test (Rails)**

```ruby
require "rails_helper"

RSpec.describe "API export", type: :request do
  it "exports for a bound stored connection with select_tags, as the agent" do
    connection = create(:kong_connection, :stored, auth_username: "ro", auth_secret: "pw")
    _pat, raw = PersonalAccessToken.issue!(operator: "o", issued_by_username: "u", connection_ids: [ connection.id ])
    allow(Kong::DeckCli).to receive(:dump).and_return("_format_version: \"3.0\"\nservices: []\n")

    get api_v1_exports_path, params: { connection: connection.name, select_tags: %w[managed-by-kongctl] },
      headers: { "Authorization" => "Bearer #{raw}" }

    expect(response.parsed_body.keys).to contain_exactly("yaml", "summary", "removed", "env_placeholders", "matched_nothing")
    expect(AuditEvent.last.actor_kind).to eq("agent")
  end

  it "requires select_tags and never runs decK without them" do
    connection = create(:kong_connection, :stored, auth_username: "ro", auth_secret: "pw")
    _pat, raw = PersonalAccessToken.issue!(operator: "o", issued_by_username: "u", connection_ids: [ connection.id ])
    allow(Kong::DeckCli).to receive(:dump)

    get api_v1_exports_path, params: { connection: connection.name }, headers: { "Authorization" => "Bearer #{raw}" }

    expect(response).to have_http_status(:unprocessable_entity)
    expect(response.parsed_body["error"]).to match(/select_tags/)
    expect(Kong::DeckCli).not_to have_received(:dump)
  end
end
```

- [ ] **Step 2: test (MCP)** — `tools.test.ts`: `kong_export` ต้องมี `connection` (string, required) และ `select_tags` (array min 1); เรียก `client.exportConfig` ด้วยค่าที่ส่ง
- [ ] **Step 3:** FAIL → implement → PASS (rspec + vitest) · Commit `feat(R7.4): kong_export for agents through the same sanitizer`

---

### Task R7.5: หน้า export (UI)

**ชั้น:** UI · **ต้องเสร็จก่อน:** R7.3, R3.4 · **ไฟล์ที่แก้ได้:** `app/views/exports/*`, `app/views/layouts/application.html.erb` (nav "Export"), `app/assets/tailwind/application.css`, `config/locales/hints.en.yml` (`hints.fields.export.select_tags`, `hints.pages.export.intro`, `hints.risks.export_sync`, `hints.risks.export_matched_nothing`, `hints.empty_states.export`), `spec/requests/ui_snapshots_spec.rb`

**คำสั่ง:** `/impeccable shape config export page` → `/impeccable clarify` (คำเตือน sync ลบของ ต้องเจาะจงและสุภาพตาม copy register) → `/impeccable harden` (YAML ยาว, tag ยาว, 390px)

- [ ] **Step 1:** assertion (ก่อน): หน้า preview แสดงคำเตือน `hints.risks.export_sync.title` ก่อนปุ่ม Download; รายการที่ถูกตัด/แทนเป็นตาราง (`scope="col"`); env placeholder เป็นรายการที่คัดลอกได้; YAML อยู่ใน region ที่ focus ได้และเลื่อนได้
- [ ] **Step 2:** FAIL → ทำ UI · PASS · snapshot (ปกติ, matched nothing, error decK) · detect · ภาพ 390/1280
- [ ] **Step 3:** Commit `feat(R7.5): export page with preview, what was removed, and the sync warning`

---

### Task R7.6: ตรวจ flow จริง (verification)

**ชั้น:** — · **ต้องเสร็จก่อน:** R7.1–R7.5

- [ ] compose `local/dev`: tag service/route/plugin 2–3 ตัวด้วย `export-demo` (ผ่าน Kongsole) → export `export-demo` → ไม่มี admin path, ไม่มี credential (`grep -E "credentials|PRIVATE KEY|password"` ว่าง)
- [ ] export ซ้ำ 2 ครั้ง → `sha256sum` เท่ากัน
- [ ] `deck file validate <file>` ผ่าน (ตั้ง env placeholder เป็นค่า dummy)
- [ ] `deck gateway diff <file>` กับ `local/dev-ro` (Kong เดียวกัน) → ไม่มี `deleting` ของ entity ที่ไม่ใช่ placeholder
- [ ] MCP `kong_export` บน `local/dev` (stored) ได้ผลเดียวกัน
- [ ] ภาพหน้าจอ

## เกณฑ์ปิดงาน R7

- [ ] เกณฑ์ใน `R7-export-config.md` (ฉบับแก้ §C8) ครบ พร้อมหลักฐาน
- [ ] test อัตโนมัติยืนยันไม่มี credential / private key / admin path (R7.2)
- [ ] `bundle exec rspec` 0 failures · vitest ผ่าน · detect ไม่เพิ่ม · `hints:todo` รายงาน
- [ ] ไม่มีไฟล์ YAML ของ export เหลือบนดิสก์ของเครื่องที่รัน (`find tmp storage -name "*.yaml" -newer <start>`)
