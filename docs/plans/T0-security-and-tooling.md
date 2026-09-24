# T0 — Security fixes and tooling Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** ปิดการละเมิดกฎข้อ 4 ที่มีอยู่แล้ว (token ฝังในโค้ด, secret ของ plugin เข้า read-model), แก้ catalog plugin ที่ว่างบน Kong ใหม่, ทำให้ test ผ่านครบ และทำ snapshot HTML ให้ `impeccable detect` ใช้ได้จริง

**Architecture:** Redactor รับ "path ของ field ลับ" ที่อ่านจาก schema ของ plugin บน connection นั้น (`Kong::PluginSecretFields`) โดย fail-closed ด้วย heuristic เมื่ออ่าน schema ไม่ได้ ทุกจุดที่ redact entity ชนิด plugin ต้องผ่าน `Kong::Redactor.for_connection` ตัวเดียว

**Tech Stack:** Rails 8.1, RSpec + WebMock, vitest (mcp/), `npx impeccable detect`

**Spec:** `docs/plans/00-roadmap.md` (Q1, Q2), `CLAUDE.md` กฎข้อ 4, `docs/DESIGN.md` §8

## Global Constraints

- ห้ามคืน credential ผ่าน API ใดๆ ห้าม log header `Authorization`
- ข้อมูลอ่อนไหวต้องผ่าน redactor ก่อนเข้า read-model — ไม่มี flag ปลด
- ทดสอบกับ compose ในเครื่องหรือ env rank 0 เท่านั้น; เรียก Admin API แบบอ่านเท่านั้นระหว่างตรวจ
- Redactor MARK = `"[REDACTED]"` (ค่าคงที่เดิม `Kong::Redactor::MARK`)

## Review Focus

1. plugin ที่ schema มี field ลับซ้อนลึก (`config.redis.password`) → ต้องถูก redact ที่ความลึกใดก็ได้ — test ใน T0.2
2. ดึง schema ไม่ได้ (Kong 5xx / timeout) ระหว่าง sync → ต้องไม่บันทึก plaintext (fail-closed) — test ใน T0.2
3. `config.headers` ของ http-log / opentelemetry มี `Authorization` → redact ทั้ง map — test ใน T0.2
4. plugin ที่ plan เดิม/audit เดิมเก็บ secret ไว้แล้ว → rake task ล้างย้อนหลัง — test ใน T0.3
5. custom plugin ที่ schema มี `referenceable` แต่ค่าเป็น `{vault://...}` → ต้องคงค่า reference ไว้ (ไม่ใช่ secret) — test ใน T0.2

---

### Task T0.0: แก้ไฟล์ requirement ตามที่อนุมัติ

**ชั้น:** docs · **ต้องเสร็จก่อน:** — · **ไฟล์ที่แก้ได้:** `docs/requirements/*.md`, `CLAUDE.md` (กฎข้อ 2 เท่านั้น)

(เจ้าของงานอนุมัติ §B และ §C เมื่อ 2026-09-24)

- [x] **Step 1:** แก้ตาม `docs/plans/design-amendments.md` §C1–C9 ทุกข้อ ตามตัวอักษร
- [x] **Step 1b:** แก้ `CLAUDE.md` กฎข้อ 2 ตาม §B ตามตัวอักษร ห้ามแตะกฎข้ออื่น
- [x] **Step 2:** `git diff --stat` ต้องแตะ 9 ไฟล์ใน `docs/requirements/` และ `CLAUDE.md` เท่านั้น
- [x] **Step 3:** Commit

```bash
git add docs/requirements CLAUDE.md
git commit -m "docs(T0.0): apply agreed requirement decisions and scope rule 2 to PR-mode rendering"
```

---

### Task T0.1: MCP อ่าน token จาก environment

**ชั้น:** backend (MCP) · **ต้องเสร็จก่อน:** — · **ไฟล์ที่แก้ได้:** `mcp/src/config.ts`, `mcp/src/config.test.ts`

**สถานะ PAT (ตรวจ 2026-09-24):** ไม่พบ token ที่ขึ้นต้น `kctl_b27f7f` ในทุก DB ของเครื่องนี้ (`kong_integration_development`, `kong_integration_test`, `kongsole`) จึงใช้กับเครื่องนี้ไม่ได้อยู่แล้ว — ผู้ที่ออก token (เครื่องของ commit `466b1ae`) ต้อง revoke ในหน้า Tokens ของเครื่องตัวเอง

**Interfaces:** Produces `loadConfig(env: NodeJS.ProcessEnv): Config` — throws `KONGCTL_TOKEN is required …` เมื่อไม่มี token

- [x] **Step 1: เพิ่ม test ที่ยืนยันว่าไม่มี token ใน source**

```ts
// mcp/src/config.test.ts — เพิ่มใน describe("loadConfig")
import { readFileSync } from "node:fs";

it("never carries a token literal in source", () => {
  const source = readFileSync(new URL("./config.ts", import.meta.url), "utf8");
  expect(source).not.toMatch(/kctl_[0-9a-f]{8,}/);
});

it("reads the token from KONGCTL_TOKEN", () => {
  expect(loadConfig({ KONGCTL_TOKEN: "kctl_test" }).token).toBe("kctl_test");
});
```

- [x] **Step 2:** `cd mcp && npm test` → FAIL 2 ข้อ (test เดิม "throws a clear error…" ล้มอยู่แล้ว + test ใหม่)
- [x] **Step 3: แก้**

```ts
export function loadConfig(env: NodeJS.ProcessEnv = process.env): Config {
  const token = env.KONGCTL_TOKEN?.trim();
  if (!token) {
    throw new Error(
      "KONGCTL_TOKEN is required -- issue a personal access token from the Kongsole web UI " +
        "(/personal_access_tokens) and set it in this server's environment."
    );
  }
  const apiUrl = (env.KONGCTL_API_URL ?? "http://localhost:3000/api/v1").replace(/\/+$/, "");
  return { apiUrl, token };
}
```

- [x] **Step 4:** `cd mcp && npm test` → **28/28 pass**
- [x] **Step 5:** Commit `fix(T0.1): mcp reads KONGCTL_TOKEN from the environment, no token in source`

**เกณฑ์ผ่าน:** vitest ผ่านทั้งหมด · `git grep -n "kctl_[0-9a-f]\{8\}" -- mcp/src` ว่าง

---

### Task T0.2: Redactor อ่าน field ลับจาก schema ของ plugin

**ชั้น:** backend · **ต้องเสร็จก่อน:** T0.4 (test ต้องรันได้ครบ) · **ไฟล์ที่แก้ได้:**
- Create: `app/services/kong/plugin_secret_fields.rb`, `spec/services/kong/plugin_secret_fields_spec.rb`
- Modify: `app/services/kong/redactor.rb`, `app/services/kong/entity_sync.rb`, `app/services/kong/change_planner.rb` (`fetch_current`), `app/controllers/entities_controller.rb` (`editable_payload`), `spec/services/kong/redactor_spec.rb`, `spec/services/kong/entity_sync_spec.rb`, `spec/services/kong/change_planner_spec.rb`

**Interfaces:**
- Produces `Kong::PluginSecretFields.paths(schema) -> Array<Array<String>>` — path จาก root ของ entity เช่น `[["config","aws_key"],["config","redis","password"]]`
- Produces `Kong::PluginSecretFields.fetch(client:, plugin_name:) -> Array<Array<String>> | nil` (nil = อ่าน schema ไม่ได้) memoize ต่อ instance
- Produces `Kong::Redactor.call(entity_type, data, secret_paths: nil)` — สำหรับ `plugin`: `secret_paths: nil` = fail-closed heuristic
- Produces `Kong::Redactor.for_connection(entity_type, data, client:, schema_fields: Kong::PluginSecretFields.new)` — จุดเดียวที่ caller ใช้

- [x] **Step 1: test ของ PluginSecretFields**

```ruby
# spec/services/kong/plugin_secret_fields_spec.rb
require "rails_helper"

RSpec.describe Kong::PluginSecretFields do
  let(:schema) do
    { "fields" => [
      { "name" => { "type" => "string" } },
      { "config" => { "type" => "record", "fields" => [
        { "aws_key" => { "type" => "string", "encrypted" => true, "referenceable" => true } },
        { "timeout" => { "type" => "number" } },
        { "redis" => { "type" => "record", "fields" => [
          { "password" => { "type" => "string", "referenceable" => true } },
          { "host" => { "type" => "string" } }
        ] } }
      ] } }
    ] }
  end

  it "lists every encrypted or referenceable field at any depth" do
    expect(described_class.paths(schema)).to contain_exactly(%w[config aws_key], %w[config redis password])
  end

  it "returns nil when the schema cannot be read, so the caller fails closed" do
    client = instance_double(Kong::Client)
    allow(client).to receive(:get).and_raise(Kong::Client::UpstreamUnavailable.new("down"))
    expect(described_class.new.fetch(client: client, plugin_name: "aws-lambda")).to be_nil
  end
end
```

- [x] **Step 2: test ของ Redactor**

```ruby
# spec/services/kong/redactor_spec.rb — เพิ่ม
describe "plugins" do
  let(:plugin) do
    { "name" => "aws-lambda", "config" => {
      "aws_key" => "AKIAREALKEY", "aws_region" => "ap-southeast-1",
      "redis" => { "password" => "pw", "host" => "r" },
      "vaulted" => "{vault://env/aws-secret}"
    } }
  end

  it "redacts the schema's secret paths at any depth" do
    data = described_class.call("plugin", plugin, secret_paths: [%w[config aws_key], %w[config redis password]])[:data]
    expect(data.dig("config", "aws_key")).to eq(described_class::MARK)
    expect(data.dig("config", "redis", "password")).to eq(described_class::MARK)
    expect(data.dig("config", "aws_region")).to eq("ap-southeast-1")
  end

  it "keeps a vault reference visible on a referenceable field -- it names a variable, it is not a secret" do
    data = described_class.call("plugin", plugin, secret_paths: [%w[config vaulted]])[:data]
    expect(data.dig("config", "vaulted")).to eq("{vault://env/aws-secret}")
  end

  it "fails closed without a schema: secret-looking names and any headers map are redacted" do
    input = { "name" => "http-log", "config" => {
      "http_endpoint" => "https://x", "headers" => { "Authorization" => "Basic abc" }, "api_token" => "t" } }
    data = described_class.call("plugin", input, secret_paths: nil)[:data]
    expect(data.dig("config", "headers")).to eq(described_class::MARK)
    expect(data.dig("config", "api_token")).to eq(described_class::MARK)
    expect(data.dig("config", "http_endpoint")).to eq("https://x")
  end
end
```

- [x] **Step 3: test ของ EntitySync (ไม่มี plaintext เข้า DB)**

```ruby
# spec/services/kong/entity_sync_spec.rb — เพิ่ม
it "stores an aws-lambda plugin with its schema-marked secrets redacted" do
  connection = create(:kong_connection, admin_url: "https://kong.test")
  client = Kong::Client.new(connection: connection, secret: "pw")
  stub_request(:get, "https://kong.test/plugins").with(query: hash_including({}))
    .to_return(status: 200, body: { data: [ { id: SecureRandom.uuid, name: "aws-lambda", tags: [],
      config: { aws_key: "AKIAREALKEY", aws_secret: "s3cr3t", aws_region: "ap-southeast-1" } } ], offset: nil }.to_json)
  stub_request(:get, "https://kong.test/schemas/plugins/aws-lambda").to_return(status: 200, body: { fields: [
    { config: { type: "record", fields: [
      { aws_key: { type: "string", encrypted: true, referenceable: true } },
      { aws_secret: { type: "string", encrypted: true, referenceable: true } } ] } } ] }.to_json)

  described_class.new(connection: connection, client: client, entity_type: "plugin").call

  stored = KongEntity.find_by!(entity_type: "plugin").data.to_json
  expect(stored).not_to include("AKIAREALKEY")
  expect(stored).not_to include("s3cr3t")
end

it "still stores no plaintext when the plugin schema cannot be fetched" do
  connection = create(:kong_connection, admin_url: "https://kong.test")
  client = Kong::Client.new(connection: connection, secret: "pw")
  stub_request(:get, "https://kong.test/plugins").with(query: hash_including({}))
    .to_return(status: 200, body: { data: [ { id: SecureRandom.uuid, name: "team-oauth", tags: [],
      config: { client_secret: "s3cr3t", headers: { "Authorization" => "Basic abc" }, timeout: 5 } } ], offset: nil }.to_json)
  stub_request(:get, "https://kong.test/schemas/plugins/team-oauth").to_return(status: 503, body: "{}")

  described_class.new(connection: connection, client: client, entity_type: "plugin").call

  stored = KongEntity.find_by!(entity_type: "plugin").data
  expect(stored.to_json).not_to include("s3cr3t")
  expect(stored.to_json).not_to include("Basic abc")
  expect(stored.dig("config", "timeout")).to eq(5)
end
```

- [x] **Step 4:** รัน `bundle exec rspec spec/services/kong/plugin_secret_fields_spec.rb spec/services/kong/redactor_spec.rb spec/services/kong/entity_sync_spec.rb` → FAIL (`uninitialized constant Kong::PluginSecretFields` / plaintext stored)

- [x] **Step 5: เขียน `Kong::PluginSecretFields`**

```ruby
module Kong
  # Which fields of a plugin are secret, read from that plugin's own schema on
  # the connection being synced (docs/DESIGN.md section 8). A custom plugin's
  # secrets are only knowable this way.
  class PluginSecretFields
    def self.paths(schema, prefix = [])
      Array(schema["fields"]).flat_map do |field|
        name, spec = field.first
        next [] unless spec.is_a?(Hash)

        path = prefix + [ name ]
        own = spec["encrypted"] || spec["referenceable"] ? [ path ] : []
        nested = spec["fields"] ? paths(spec, path) : []
        own + nested
      end
    end

    def initialize
      @cache = {}
    end

    # nil when Kong would not say -- the caller must then fail closed.
    def fetch(client:, plugin_name:)
      return @cache[plugin_name] if @cache.key?(plugin_name)

      body = client.get("/schemas/plugins/#{ERB::Util.url_encode(plugin_name)}").body
      body = JSON.parse(body) if body.is_a?(String)
      @cache[plugin_name] = self.class.paths(body)
    rescue Kong::Client::Error, JSON::ParserError
      @cache[plugin_name] = nil
    end
  end
end
```

- [x] **Step 6: แก้ `Kong::Redactor`** — เพิ่ม `secret_paths:` (ค่า default `:unused` เพื่อให้ type อื่นทำงานเหมือนเดิม), สำหรับ `plugin`:
  - `secret_paths` เป็น Array → redact แต่ละ path ที่ค่าไม่ใช่ `nil` และไม่ใช่ reference (`/\A\{vault:\/\/[^}]+\}\z/`)
  - `secret_paths == nil` → fail-closed: redact ทุก key ใต้ `config` (ทุกความลึก) ที่ชื่อ match `FAIL_CLOSED_NAME = /(key|secret|password|passwd|token|credential|auth|private|cert)/i` และทุก key ชื่อ `headers`
  - คง `SCHEMA_MARKED_FIELDS` เดิมไว้เป็นชั้นที่สอง
  - เพิ่ม `def self.for_connection(entity_type, data, client:, schema_fields: Kong::PluginSecretFields.new)` → ถ้า plugin: `call(entity_type, data, secret_paths: schema_fields.fetch(client:, plugin_name: data["name"]))` ไม่งั้น `call(entity_type, data)`
- [x] **Step 7:** เปลี่ยน caller ทั้งสามให้ใช้ `Kong::Redactor.for_connection`: `EntitySync` (สร้าง `PluginSecretFields.new` หนึ่งตัวต่อการ sync หนึ่งรอบ), `ChangePlanner#fetch_current`, `EntitiesController#editable_payload`
- [x] **Step 8:** รันทั้ง 3 ไฟล์ + `spec/services/kong/change_planner_spec.rb spec/requests/entities_spec.rb` → PASS
- [x] **Step 9:** รันทั้ง suite → 0 failures
- [x] **Step 10:** Commit `fix(T0.2): redact plugin secrets from each plugin's own schema, fail closed without it`

**เกณฑ์ผ่าน:** test ใหม่ทั้งหมดผ่าน · suite 0 failures · ตรวจกับ compose: สร้าง plugin `aws-lambda` บน `dev-readwrite` (rank 0) ด้วย `aws_secret: "probe-secret"` → Sync now → `bin/rails runner 'puts KongEntity.where(entity_type: "plugin").pluck(:data).to_json.include?("probe-secret")'` ต้องได้ `false` แล้วลบ plugin ทิ้ง

---

### Task T0.3: ล้าง secret ของ plugin ที่เก็บไว้แล้ว

**ชั้น:** backend · **ต้องเสร็จก่อน:** T0.2 · **ไฟล์ที่แก้ได้:** Create `lib/tasks/redact.rake`, `app/services/kong/stored_plugin_redaction.rb`, `spec/services/kong/stored_plugin_redaction_spec.rb`

**Interfaces:** Produces `Kong::StoredPluginRedaction.call -> {entities:, plans:, audit_events:}` (จำนวนแถวที่แก้)

- [x] **Step 1: test**

```ruby
require "rails_helper"

RSpec.describe Kong::StoredPluginRedaction do
  it "re-redacts plugin rows, plan snapshots and audit diffs already on disk (fail-closed rules)" do
    connection = create(:kong_connection)
    entity = create(:kong_entity, kong_connection: connection, entity_type: "plugin",
      data: { "name" => "http-log", "config" => { "headers" => { "Authorization" => "Basic abc" } } })
    plan = create(:change_plan, kong_connection: connection, entity_type: "plugin",
      after: { "name" => "aws-lambda", "config" => { "aws_secret" => "s3cr3t" } })
    event = create(:audit_event, kong_connection: connection, entity_type: "plugin",
      diff: { "config" => { "from" => { "client_secret" => "old" }, "to" => { "client_secret" => "new" } } })

    counts = described_class.call

    expect(entity.reload.data.to_json).not_to include("Basic abc")
    expect(plan.reload.after.to_json).not_to include("s3cr3t")
    expect(event.reload.diff.to_json).not_to match(/"old"|"new"/)
    expect(counts).to eq(entities: 1, plans: 1, audit_events: 1)
  end
end
```

- [x] **Step 2:** รัน → FAIL
- [x] **Step 3:** เขียน service ใช้ `Kong::Redactor.call("plugin", …, secret_paths: nil)` กับ `kong_entities.data`, `change_plans.before/after`, และทุกค่า `from`/`to` ของ `audit_events.diff` กับ `change_plans.diff` เฉพาะแถว `entity_type = "plugin"`; คำนวณ `digest` ใหม่ของ entity; นับเฉพาะแถวที่เปลี่ยน; rake `kong:redact_stored_plugin_secrets` เรียก service แล้ว print จำนวน
- [x] **Step 4:** รัน → PASS · รันทั้ง suite → 0 failures
- [x] **Step 5:** Commit `fix(T0.3): scrub plugin secrets already stored in the read-model, plans and audit`

**เกณฑ์ผ่าน:** test ผ่าน · รัน `bin/rails kong:redact_stored_plugin_secrets` บน DB dev ในเครื่องได้ไม่ error

---

### Task T0.4: test environment ที่รันผ่านครบ

**ชั้น:** backend (config) · **ต้องเสร็จก่อน:** — (ทำเป็นอันดับแรกของ T0 ต่อจาก T0.0) · **ไฟล์ที่แก้ได้:** `config/environments/test.rb`, `config/database.yml` (เฉพาะ block `test:`)

- [x] **Step 1:** รัน `bundle exec rspec` (ไม่ตั้ง `DATABASE_URL`) → คาดว่าเชื่อม DB ไม่ได้; รันด้วย `DATABASE_URL` → 843/49 (บันทึกเป็นหลักฐาน RED)
- [x] **Step 2: แก้**

```yaml
# config/database.yml
test:
  <<: *default
  database: kong_integration_test
  username: kongsole
  password: kongsole
  host: localhost
  port: 5433
```

```ruby
# config/environments/test.rb — ภายใน configure block
# Test-only keys: never real, never used outside RAILS_ENV=test. Lets the
# ActiveRecord::Encryption specs run without config/master.key.
config.active_record.encryption.primary_key = "test-primary-key-kongsole-000000"
config.active_record.encryption.deterministic_key = "test-deterministic-key-kongsole-0"
config.active_record.encryption.key_derivation_salt = "test-key-derivation-salt-kongsole"
```

- [x] **Step 3:** `bundle exec rspec` → **843 examples, 0 failures**
- [x] **Step 4:** `bundle exec rubocop config/environments/test.rb` สะอาด
- [x] **Step 5:** Commit `chore(T0.4): test env runs the whole suite without master.key`

**เกณฑ์ผ่าน:** 0 failures · ค่าใน `test.rb` ไม่ถูกอ่านใน development/production (`grep -rn "test-primary-key" config` เจอไฟล์เดียว)

---

### Task T0.5: catalog plugin ใช้ `available_on_server`

**ชั้น:** backend · **ต้องเสร็จก่อน:** T0.4 · **ไฟล์ที่แก้ได้:** `app/controllers/plugins_controller.rb`, `app/services/kong/connection_login.rb` (comment), `spec/requests/plugins_spec.rb`

- [ ] **Step 1: แก้ test เดิมที่ล็อกพฤติกรรมผิด**

```ruby
it "lists every plugin loaded on this node, including ones with no instance yet" do
  sign_in
  connection.update!(plugins_available: {
    "enabled_in_cluster" => %w[acl basic-auth],
    "available_on_server" => { "acl" => {}, "basic-auth" => {}, "rate-limiting" => {}, "my-custom" => {} }
  })

  get new_plugin_path

  %w[acl basic-auth rate-limiting my-custom].each { |name| expect(response.body).to include(name) }
end
```

- [ ] **Step 2:** รัน → FAIL (rate-limiting ไม่แสดง)
- [ ] **Step 3:** `@catalog = current_connection.plugins_available.fetch("available_on_server", {}).keys.sort` และแก้ comment ใน `connection_login.rb` ให้บอกความหมายที่ถูก (available_on_server = plugin ที่โหลดบน node นี้, enabled_in_cluster = ที่มี instance แล้ว; ยืนยันกับ Kong 3.7.1: 43 vs 2)
- [ ] **Step 4:** PASS · suite 0 failures
- [ ] **Step 5:** Commit `fix(T0.5): plugin catalog lists plugins loaded on the node, not only ones already in use`

(comment ใน `app/views/plugins/new.html.erb` บรรทัด 9–11 ยังผิด — แก้ใน R4.7 ชั้น UI)

---

### Task T0.6: snapshot HTML สำหรับ `impeccable detect` + baseline ใหม่

**ชั้น:** backend (test tooling) · **ต้องเสร็จก่อน:** T0.4 · **ไฟล์ที่แก้ได้:** Create `spec/support/ui_snapshots.rb`, `spec/requests/ui_snapshots_spec.rb`; Modify `.gitignore` (เพิ่ม `/tmp/ui-snapshots`), `docs/plans/00-roadmap.md` (ตาราง baseline เท่านั้น)

**Interfaces:** Produces helper `snapshot!(name)` ใน request spec: เมื่อ `ENV["UI_SNAPSHOTS"] == "1"` เขียน `response.body` ไป `tmp/ui-snapshots/<name>.html` โดยแทน `<link rel="stylesheet" …>` ด้วย `<style>` ของ `app/assets/builds/tailwind.css` · Later tasks: เพิ่มหน้าใหม่ของตัวเองเข้า `ui_snapshots_spec.rb`

- [ ] **Step 1: test**

```ruby
# spec/requests/ui_snapshots_spec.rb
require "rails_helper"

RSpec.describe "UI snapshots", type: :request do
  include UiSnapshots

  it "writes the connections index with the stylesheet inlined" do
    create(:kong_connection, name: "dev-1")
    get connections_path
    path = snapshot!("connections-index", force: true)
    html = File.read(path)
    expect(html).to include("<style>")
    expect(html).not_to include('rel="stylesheet" href="/assets')
  end
end
```

- [ ] **Step 2:** FAIL → เขียน `UiSnapshots` (`force:` ใช้ใน test นี้เท่านั้น) → PASS
- [ ] **Step 3:** เพิ่ม example ต่อหน้าที่มีอยู่ (login, health, entities index ทุก tab, entity show, entities new ทุก type, plugins new ทั้งสองขั้น, change_plans show direct/pr/delete, change_plans index, audit, tokens index/new, certificates expiring, connections new) — sign in ด้วย WebMock stub แบบเดียวกับ `spec/requests/plugins_spec.rb#sign_in`; แต่ละ example เรียก `snapshot!("<page>")`
- [ ] **Step 4:** `UI_SNAPSHOTS=1 bundle exec rspec spec/requests/ui_snapshots_spec.rb` แล้ว `npx impeccable detect --json tmp/ui-snapshots > tmp/detect-baseline.json`
- [ ] **Step 5:** บันทึกจำนวน finding ต่อหน้าลงตาราง baseline ใน `00-roadmap.md` (แถวใหม่ "detect บน snapshot")
- [ ] **Step 6:** Commit `test(T0.6): render pages to HTML snapshots so impeccable detect can scan them`

**เกณฑ์ผ่าน:** snapshot ≥ 18 หน้า · detect รันจบ (exit 0 หรือ 2) · ตัวเลข baseline อยู่ใน roadmap

---

## เกณฑ์ปิดงาน T0

- [ ] `bundle exec rspec` → 0 failures (≥ 843 + test ใหม่)
- [ ] `cd mcp && npm test` → ผ่านทั้งหมด
- [ ] ไม่มี plaintext secret ของ plugin ใน read-model (ตรวจตาม T0.2) · PAT เก่าถูก revoke (เจ้าของงานยืนยัน)
- [ ] detect baseline บน snapshot บันทึกแล้ว
- [ ] รายงาน: ผล test, diff baseline, ยืนยัน `spec/requests/log_filtering_spec.rb` ผ่าน
