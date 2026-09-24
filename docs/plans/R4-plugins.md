# R4 — Plugins with schema and hints Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** catalog ที่ค้นหาได้จาก plugin ที่โหลดบน node จริง (รวม custom) พร้อมคำอธิบาย, ฟอร์มสร้างจาก schema ของ connection นั้น (field ลับแสดงแบบ mask และแนะนำ `{vault://env/…}`), เลือก scope ได้ 4 แบบ, เตือนเมื่อ schema ต่างจาก env อื่นใน project, ผ่าน plan (direct) หรือ changeset (pr)

**Architecture:** `Kong::SchemaCache` (ตาราง `kong_schemas`) เก็บ schema ต่อ connection + kong_version + ชื่อ ใช้ร่วมกันโดย redactor (T0.2), ฟอร์ม และการเตือนเวอร์ชัน · `Kong::PluginSchemaForm` แปลง schema เป็น descriptor ของ field (scalar → input, ซ้อน → JSON sub-editor) · `Kong::PluginSecretPolicy` บังคับว่า PR mode ห้ามมีค่าลับ plaintext (ต้องเป็น vault reference หรือ decK env placeholder) · คำอธิบาย bundled อยู่ใน `hints.plugins.*`, custom อยู่ใน `config/custom_plugins/<name>.yml`

**Tech Stack:** Rails 8.1, Stimulus, RSpec + WebMock

**Spec:** `docs/requirements/R4-plugins.md` (+ `design-amendments.md` §C5, §A5), `docs/DESIGN.md` §14 "ฟอร์ม plugin สร้างจาก schema", `docs/plans/00-roadmap.md` (Q18, Q19)

## Global Constraints

- catalog = `plugins_available["available_on_server"]` ของ connection (T0.5); plugin ที่ไม่ได้โหลดไม่แสดง
- ค่าที่ schema ระบุ `encrypted`/`referenceable` ไม่ถูก prefill ด้วยค่าจริง, ไม่กลับไปที่ UI หรือ MCP (read-model redacted แล้วตั้งแต่ T0.2)
- **PR mode:** field ลับต้องเป็น `{vault://env/<name>}` หรือ `${{ env "DECK_<NAME>" }}` — plaintext ถูกปฏิเสธ (ไม่อย่างนั้นความลับจะเข้า git)
- **direct mode:** plaintext ยอมรับ แต่ UI แนะนำ vault reference และ plan review ไม่แสดงค่า
- plugin บน admin path: read-only ไม่มี override (`ChangeGuardrails.check_plugin_immutable!` เดิม); scope picker ไม่เสนอ entity admin path
- Kong CE: vault backend `env` เท่านั้น

## Review Focus

1. custom plugin ที่ไม่มีไฟล์ metadata → catalog บอกชัด "No description provided for this custom plugin" + วิธีเพิ่ม — test ใน R4.2
2. schema มี field `record` ซ้อน 3 ชั้น (เช่น `config.redis.cluster_nodes[]`) → กลายเป็น JSON sub-editor ของ `redis` ไม่ใช่ field หาย — test ใน R4.3
3. ส่ง form โดยเว้น field ที่มี default → ส่ง default ของ schema ไม่ใช่ `""` หรือ `nil` — test ใน R4.4
4. ค่า number พิมพ์ `"1e3"` / `"abc"` → error ที่ field นั้น ไม่ใช่ 500 — test ใน R4.4
5. Kong ต่างเวอร์ชันระหว่าง `project-a/dev` และ `project-a/uat` → หน้า config เตือนพร้อมชื่อ env และเวอร์ชัน — test ใน R4.5

---

## Spec ที่ตกลงแล้ว

- **Catalog:** ค้นหาตามชื่อ/คำอธิบาย; แบ่ง "Bundled with Kong" / "Custom"; แต่ละแถว: ชื่อ, คำอธิบาย 1 บรรทัด, `version` + `priority` จาก `available_on_server`
- **Bundled vs custom:** ชื่อที่อยู่ใน `config/kong_bundled_plugins.yml` (รายชื่อ bundled ของ Kong 3.x) = bundled; นอกนั้น = custom
- **Custom metadata** `config/custom_plugins/<name>.yml`:
  ```yaml
  description: One line about what it does.
  docs_url: https://git.example/team/kong-plugins/<name>   # optional
  fields:                                                   # optional, key = dotted path under config
    upstream_header: Header the plugin adds before proxying.
  ```
- **Scope:** Global / Service / Route / Consumer — เมื่อเข้าจากหน้า entity ใช้ scope นั้น; จาก catalog เลือกได้ (select ที่ค้นหาได้ของ read-model, ไม่รวม admin path)
- **Form:** field ระดับบนของ `config` ที่เป็น string/number/integer/boolean/enum/array|set ของ scalar → control; `record`/`map`/array ของ record → JSON sub-editor ของ field นั้น (validate JSON ฝั่ง client + server); ส่วน "Advanced: edit the whole plugin as JSON" คง JSON editor เดิมไว้
- **Schema mismatch:** digest ของ schema plugin เดียวกันบน env อื่นใน project ที่มีใน cache ต่างกัน → เตือน "Schema differs on <env> (Kong <version>)"

## Contract UI ↔ backend

| backend ให้ | รายละเอียด |
|---|---|
| `@catalog` | `Array<Kong::PluginCatalog::Entry(name:, custom:, summary:, docs_url:, version:, priority:)>` เรียงตามชื่อ |
| `@scope_options` | `{ "service" => [[label, kong_id]], "route" => [...], "consumer" => [...] }` ไม่รวม admin path |
| `@fields` | `Array<Kong::PluginSchemaForm::Field(path:, name:, kind:, required:, default:, one_of:, secret:, description:, help:)>` — `kind` ∈ `:string :number :integer :boolean :enum :list :json` |
| `@schema_mismatch` | `Array<{env:, kong_version:}>` |
| `@secret_policy` | `:reference_required` (pr) / `:reference_recommended` (direct) |
| params ของฟอร์ม | `plugin[config][<name>]` ต่อ field; `:list` = textarea คั่นบรรทัด; `:json` = text JSON; `plugin[enabled]`, `plugin[tags]`, `plugin[protocols][]`; ทางเลือก `payload_json` (Advanced) |
| error | `@field_errors` = `{ "config.<name>" => [msg] }` + `render :new, 422` |

---

### Task R4.1: schema cache (backend)

**ชั้น:** backend · **ต้องเสร็จก่อน:** R1, T0.2 · **ไฟล์ที่แก้ได้:** Create `db/migrate/<ts>_create_kong_schemas.rb`, `app/models/kong_schema.rb`, `app/services/kong/schema_cache.rb`, `spec/services/kong/schema_cache_spec.rb`; Modify `app/services/kong/plugin_secret_fields.rb` (ใช้ SchemaCache), `app/services/kong/entity_schema.rb` (R3.3 → ใช้ SchemaCache), `spec/services/kong/plugin_secret_fields_spec.rb`

**Interfaces:** `Kong::SchemaCache.fetch(connection:, client:, kind:, name:) -> Hash | nil` (`kind` ∈ `"plugin"`, `"entity"`); อายุ 24 ชม. หรือจน `kong_version` เปลี่ยน; ล้มแล้วคืน cache เก่าถ้ามี ไม่งั้น nil · `KongSchema.digest_for(connection:, kind:, name:)`

- [ ] **Step 1: test**

```ruby
require "rails_helper"

RSpec.describe Kong::SchemaCache do
  let(:connection) { create(:kong_connection, admin_url: "https://kong.test", kong_version: "3.7.1") }
  let(:client) { Kong::Client.new(connection: connection, secret: "pw") }
  let(:schema) { { "fields" => [ { "config" => { "type" => "record", "fields" => [] } } ] } }

  it "fetches once and serves from the cache for the same Kong version" do
    stub = stub_request(:get, "https://kong.test/schemas/plugins/rate-limiting").to_return(status: 200, body: schema.to_json)
    2.times { described_class.fetch(connection: connection, client: client, kind: "plugin", name: "rate-limiting") }
    expect(stub).to have_been_requested.once
  end

  it "refetches after the Kong version changes" do
    stub = stub_request(:get, "https://kong.test/schemas/plugins/rate-limiting").to_return(status: 200, body: schema.to_json)
    described_class.fetch(connection: connection, client: client, kind: "plugin", name: "rate-limiting")
    connection.update_columns(kong_version: "3.8.0")
    described_class.fetch(connection: connection, client: client, kind: "plugin", name: "rate-limiting")
    expect(stub).to have_been_requested.twice
  end

  it "serves a stale copy when Kong is down, and nil when it never had one" do
    stub_request(:get, "https://kong.test/schemas/plugins/acl").to_return(status: 503, body: "{}")
    expect(described_class.fetch(connection: connection, client: client, kind: "plugin", name: "acl")).to be_nil
  end
end
```

- [ ] **Step 2:** FAIL → migration

```ruby
class CreateKongSchemas < ActiveRecord::Migration[8.1]
  def change
    create_table :kong_schemas do |t|
      t.references :kong_connection, null: false, foreign_key: true
      t.string :kind, null: false
      t.string :name, null: false
      t.string :kong_version
      t.string :digest, null: false
      t.jsonb :body, null: false
      t.datetime :fetched_at, null: false
      t.timestamps
    end
    add_index :kong_schemas, %i[kong_connection_id kind name], unique: true
  end
end
```

- [ ] **Step 3:** implement → PASS · migrate/rollback/migrate · suite 0 failures
- [ ] **Step 4:** Commit `feat(R4.1): cache Kong schemas per connection and version`

---

### Task R4.2: catalog + metadata ของ custom plugin (backend)

**ชั้น:** backend · **ต้องเสร็จก่อน:** R4.1 · **ไฟล์ที่แก้ได้:** Create `app/services/kong/plugin_catalog.rb`, `config/kong_bundled_plugins.yml`, `config/custom_plugins/.keep`, `spec/services/kong/plugin_catalog_spec.rb`, `spec/fixtures/custom_plugins/team-auth.yml`

**Interfaces:** `Kong::PluginCatalog.for(connection, metadata_dir: Rails.root.join("config/custom_plugins")) -> Array<Entry>`; `Entry = Struct.new(:name, :custom, :summary, :docs_url, :version, :priority, :field_help, keyword_init: true)`; bundled summary = `I18n.t("hints.plugins.#{name}.summary", default: nil)`

- [ ] **Step 1: test**

```ruby
require "rails_helper"

RSpec.describe Kong::PluginCatalog do
  let(:connection) do
    create(:kong_connection, plugins_available: { "available_on_server" => {
      "rate-limiting" => { "version" => "3.7.1", "priority" => 910 },
      "team-auth" => { "version" => "0.3.0", "priority" => 1005 },
      "team-headers" => { "version" => "1.0.0", "priority" => 800 } } })
  end
  let(:dir) { Rails.root.join("spec/fixtures/custom_plugins") }

  it "lists what the node loaded, bundled and custom apart" do
    entries = described_class.for(connection, metadata_dir: dir)
    expect(entries.map { [ _1.name, _1.custom ] }).to eq([ [ "rate-limiting", false ], [ "team-auth", true ], [ "team-headers", true ] ])
  end

  it "reads a custom plugin's description from its metadata file" do
    entry = described_class.for(connection, metadata_dir: dir).find { _1.name == "team-auth" }
    expect(entry.summary).to eq("Checks the team's signed header before proxying.")
  end

  it "says plainly when a custom plugin has no description" do
    entry = described_class.for(connection, metadata_dir: dir).find { _1.name == "team-headers" }
    expect(entry.summary).to be_nil
  end

  it "never reads a metadata path outside the directory" do
    evil = create(:kong_connection, plugins_available: { "available_on_server" => { "../../secrets" => {} } })
    expect { described_class.for(evil, metadata_dir: dir) }.not_to raise_error
    expect(described_class.for(evil, metadata_dir: dir).first.summary).to be_nil
  end
end
```

- [ ] **Step 2:** FAIL → implement (ชื่อ plugin ต้อง match `/\A[a-z0-9][a-z0-9_-]*\z/` ก่อนเปิดไฟล์) → PASS
- [ ] **Step 3:** สร้าง `config/kong_bundled_plugins.yml` จาก `available_on_server` ของ compose (Kong 3.7.1, GET ผ่าน ro route) — ทั้ง 43 ชื่อ พร้อมคอมเมนต์ว่าวัดจาก Kong 3.7.1 เมื่อวันที่ทำ
- [ ] **Step 4:** Commit `feat(R4.2): plugin catalog from the node, with custom plugin metadata from the repo`

---

### Task R4.3: schema → field descriptors (backend)

**ชั้น:** backend · **ต้องเสร็จก่อน:** R4.1 · **ไฟล์ที่แก้ได้:** Create `app/services/kong/plugin_schema_form.rb`, `spec/services/kong/plugin_schema_form_spec.rb`; Modify `app/helpers/plugins_helper.rb` (ลบ `plugin_config_fields` ถ้าไม่มีที่ใช้แล้วหลัง R4.7 — ในงานนี้ห้ามลบ)

**Interfaces:** `Kong::PluginSchemaForm.fields(schema, custom_help: {}) -> Array<Field>`; `Field = Struct.new(:path, :name, :kind, :required, :default, :one_of, :secret, :description, :help, keyword_init: true)`

- [ ] **Step 1: test**

```ruby
require "rails_helper"

RSpec.describe Kong::PluginSchemaForm do
  let(:schema) do
    { "fields" => [ { "config" => { "type" => "record", "fields" => [
      { "minute" => { "type" => "number", "description" => "Requests per minute." } },
      { "policy" => { "type" => "string", "default" => "local", "one_of" => %w[local cluster redis] } },
      { "hide_client_headers" => { "type" => "boolean", "default" => false, "required" => true } },
      { "header_name" => { "type" => "string", "len_min" => 1 } },
      { "allowed" => { "type" => "set", "elements" => { "type" => "string" } } },
      { "redis" => { "type" => "record", "fields" => [ { "password" => { "type" => "string", "referenceable" => true } } ] } },
      { "api_key" => { "type" => "string", "encrypted" => true, "referenceable" => true } }
    ] } } ] }
  end

  it "maps each top-level config field to a form control" do
    kinds = described_class.fields(schema).to_h { [ _1.name, _1.kind ] }
    expect(kinds).to eq("minute" => :number, "policy" => :enum, "hide_client_headers" => :boolean,
      "header_name" => :string, "allowed" => :list, "redis" => :json, "api_key" => :string)
  end

  it "marks encrypted or referenceable fields as secret" do
    expect(described_class.fields(schema).find { _1.name == "api_key" }.secret).to be(true)
  end

  it "keeps defaults, required and allowed values" do
    policy = described_class.fields(schema).find { _1.name == "policy" }
    expect(policy).to have_attributes(default: "local", one_of: %w[local cluster redis], path: "config.policy")
  end

  it "uses custom help when the metadata gives some" do
    field = described_class.fields(schema, custom_help: { "header_name" => "Header to add." }).find { _1.name == "header_name" }
    expect(field.help).to eq("Header to add.")
  end
end
```

- [ ] **Step 2:** FAIL → implement → PASS · Commit `feat(R4.3): turn a plugin schema into form fields`

---

### Task R4.4: form params → attributes + secret policy (backend)

**ชั้น:** backend · **ต้องเสร็จก่อน:** R4.3 · **ไฟล์ที่แก้ได้:** Create `app/services/kong/plugin_form_params.rb`, `app/services/kong/plugin_secret_policy.rb`, `spec/services/kong/plugin_form_params_spec.rb`, `spec/services/kong/plugin_secret_policy_spec.rb`, `spec/fixtures/schemas/rate_limiting_like.json` (schema เดียวกับ `let(:schema)` ใน R4.3 เขียนเป็น JSON); Modify `app/services/kong/change_planner.rb` (เรียก `PluginSecretPolicy.check!` สำหรับ plugin create/update — คุมเส้นทาง MCP และ JSON editor ด้วย), `spec/services/kong/change_planner_spec.rb`

**Interfaces:**
- `Kong::PluginFormParams.call(fields:, params:) -> [attributes Hash, errors Hash]`
- `Kong::PluginSecretPolicy.check!(attributes, secret_paths:, apply_mode:)` raise `Kong::ChangePlanner::InvalidChange` (ข้อความไม่มีค่าที่ส่งมา)

- [ ] **Step 1: test**

```ruby
# spec/services/kong/plugin_form_params_spec.rb
require "rails_helper"

RSpec.describe Kong::PluginFormParams do
  let(:fields) { Kong::PluginSchemaForm.fields(schema) } # reuse the schema from plugin_schema_form_spec via a shared let
  let(:schema) { JSON.parse(File.read(Rails.root.join("spec/fixtures/schemas/rate_limiting_like.json"))) }

  it "coerces types and fills schema defaults for blank fields" do
    attrs, errors = described_class.call(fields: fields, params: { "config" => { "minute" => "60", "policy" => "",
      "hide_client_headers" => "1", "allowed" => "a\nb\n", "redis" => "{\"password\":\"{vault://env/redis-pw}\"}" } })
    expect(errors).to be_empty
    expect(attrs["config"]).to include("minute" => 60, "policy" => "local", "hide_client_headers" => true,
      "allowed" => %w[a b], "redis" => { "password" => "{vault://env/redis-pw}" })
  end

  it "reports bad numbers and bad JSON on their own fields" do
    _attrs, errors = described_class.call(fields: fields, params: { "config" => { "minute" => "abc", "redis" => "{" } })
    expect(errors.keys).to contain_exactly("config.minute", "config.redis")
  end

  it "leaves a blank secret out so an edit keeps Kong's current value" do
    attrs, = described_class.call(fields: fields, params: { "config" => { "api_key" => "" } })
    expect(attrs["config"]).not_to have_key("api_key")
  end
end
```

```ruby
# spec/services/kong/plugin_secret_policy_spec.rb
require "rails_helper"

RSpec.describe Kong::PluginSecretPolicy do
  let(:paths) { [ %w[config api_key] ] }

  it "refuses a plaintext secret in PR mode without echoing it" do
    expect { described_class.check!({ "config" => { "api_key" => "sk_live_123" } }, secret_paths: paths, apply_mode: "pr") }
      .to raise_error(Kong::ChangePlanner::InvalidChange) { |e| expect(e.message).not_to include("sk_live_123") }
  end

  it "accepts a vault reference or a decK env placeholder in PR mode" do
    [ "{vault://env/payments-api-key}", '${{ env "DECK_PAYMENTS_API_KEY" }}' ].each do |value|
      expect { described_class.check!({ "config" => { "api_key" => value } }, secret_paths: paths, apply_mode: "pr") }.not_to raise_error
    end
  end

  it "accepts plaintext in direct mode (Kong stores it; the read-model never does)" do
    expect { described_class.check!({ "config" => { "api_key" => "x" } }, secret_paths: paths, apply_mode: "direct") }.not_to raise_error
  end
end
```

- [ ] **Step 2:** FAIL → implement → PASS (planner ได้ secret_paths จาก `PluginSecretFields` ผ่าน SchemaCache; PR mode อ่าน schema ด้วย GET ผ่าน ro route ได้)
- [ ] **Step 3:** suite 0 failures · Commit `feat(R4.4): build plugin bodies from the form; no plaintext secret reaches a PR`

---

### Task R4.5: PluginsController ใช้ catalog/form/scope/mismatch (backend)

**ชั้น:** backend · **ต้องเสร็จก่อน:** R4.2, R4.4, R8 · **ไฟล์ที่แก้ได้:** `app/controllers/plugins_controller.rb`, `app/views/plugins/new.html.erb` (render ตัวแปรใหม่แบบขั้นต่ำ — field loop ธรรมดา), `app/services/kong/schema_mismatch.rb` (create), `spec/services/kong/schema_mismatch_spec.rb` (create), `spec/requests/plugins_spec.rb`

- [ ] **Step 1: test**

```ruby
# spec/requests/plugins_spec.rb — เพิ่ม
it "offers every scope, without admin-path entities" do
  sign_in
  create(:kong_entity, kong_connection: connection, entity_type: "service", name: "billing")
  create(:kong_entity, kong_connection: connection, entity_type: "service", name: "admin-api", is_admin_path: true)
  get new_plugin_path(plugin_name: "rate-limiting")
  expect(response.body).to include("billing")
  expect(response.body).not_to include("admin-api")
end

let(:schema_json) { File.read(Rails.root.join("spec/fixtures/schemas/rate_limiting_like.json")) }

def stub_schema(host = "https://kong-admin.test")
  stub_request(:get, "#{host}/schemas/plugins/rate-limiting").to_return(status: 200, body: schema_json)
end

it "creates from form fields and lands on the plan review (direct) with Kong's schema validation" do
  sign_in
  connection.update!(access_level: "rw")
  service = create(:kong_entity, kong_connection: connection, entity_type: "service", name: "billing")
  stub_schema
  validate = stub_request(:post, "https://kong-admin.test/schemas/plugins/validate").to_return(status: 200, body: "{}")

  post plugins_path, params: { plugin_name: "rate-limiting", scope_type: "service", scope_kong_id: service.kong_id,
    plugin: { config: { minute: "60" }, enabled: "1" } }

  plan = ChangePlan.last
  expect(response).to redirect_to(change_plan_path(plan))
  expect(plan.after["config"]["minute"]).to eq(60)
  expect(plan.after["service"]).to eq("id" => service.kong_id)
  expect(validate).to have_been_requested
end

it "re-renders with the field's own error for a bad value" do
  sign_in
  connection.update!(access_level: "rw")
  stub_schema
  post plugins_path, params: { plugin_name: "rate-limiting", plugin: { config: { minute: "abc" } } }
  expect(response).to have_http_status(:unprocessable_entity)
  expect(response.body).to include("config.minute")
  expect(ChangePlan.count).to eq(0)
end

it "puts a PR-mode plugin into the changeset and refuses plaintext secrets" do
  env = create(:project_env, name: "uat", apply_mode: "pr", source: "registry", select_tags: %w[managed-by-kongctl])
  pr_connection = create(:kong_connection, admin_url: "https://kong-uat.test", project_env: env)
  sign_in_to(pr_connection, access: :ro)
  stub_schema("https://kong-uat.test")

  post plugins_path, params: { plugin_name: "rate-limiting", plugin: { config: { api_key: "sk_live_1" } } }
  expect(response).to have_http_status(:unprocessable_entity)
  expect(response.body).not_to include("sk_live_1")

  post plugins_path, params: { plugin_name: "rate-limiting", plugin: { config: { api_key: "{vault://env/rl-api-key}" } } }
  expect(response).to redirect_to(changeset_path(ChangePlan.last.changeset))
  expect(a_request(:any, /kong-uat\.test/).with { |req| req.method != :get }).not_to have_been_made
end
```

```ruby
# spec/services/kong/schema_mismatch_spec.rb
require "rails_helper"

RSpec.describe Kong::SchemaMismatch do
  it "lists other envs in the project whose cached schema for the plugin differs" do
    project = create(:project, key: "project-a")
    dev = create(:kong_connection, kong_version: "3.7.1", project_env: create(:project_env, project: project, name: "dev", position: 1))
    uat = create(:kong_connection, kong_version: "3.8.0", project_env: create(:project_env, project: project, name: "uat", position: 2))
    sit = create(:kong_connection, kong_version: "3.7.1", project_env: create(:project_env, project: project, name: "sit", position: 3))
    other_project = create(:kong_connection, kong_version: "3.9.0")
    { dev => "aaa", uat => "bbb", sit => "aaa", other_project => "ccc" }.each do |conn, digest|
      KongSchema.create!(kong_connection: conn, kind: "plugin", name: "rate-limiting", kong_version: conn.kong_version,
        digest: digest, body: {}, fetched_at: Time.current)
    end

    expect(described_class.for(connection: dev, plugin_name: "rate-limiting")).to eq([ { env: "uat", kong_version: "3.8.0" } ])
  end

  it "says nothing when no other env has cached that plugin yet" do
    connection = create(:kong_connection)
    expect(described_class.for(connection: connection, plugin_name: "cors")).to eq([])
  end
end
```
(`sign_in` คือ helper เดิมของไฟล์นี้; `sign_in_to` จาก `SignInHelper` ของ R1.7; fixture มี field `api_key` แบบ `encrypted: true`)

- [ ] **Step 2:** FAIL → implement → PASS · suite 0 failures
- [ ] **Step 3:** Commit `feat(R4.5): plugin flow uses the catalog, schema form, scope picker and version check`

---

### Task R4.6: หน้า catalog (UI)

**ชั้น:** UI · **ต้องเสร็จก่อน:** R4.5, R3.4 · **ไฟล์ที่แก้ได้:** `app/views/plugins/new.html.erb` (ขั้น catalog), `app/views/plugins/_catalog.html.erb` (create), `app/views/plugins/_scope_picker.html.erb` (create), `app/javascript/controllers/list_filter_controller.js` (create), `app/assets/tailwind/application.css`, `config/locales/hints.en.yml` (`hints.empty_states.plugins_catalog`, `hints.pages.plugins_new.intro`, `hints.fields.plugin.scope`), `spec/requests/ui_snapshots_spec.rb`

**คำสั่ง:** `/impeccable distill app/views/plugins` (ข้อ critique เดิม: catalog ค้นหาไม่ได้) → `/impeccable onboard` → `/impeccable harden`

- [ ] **Step 1:** assertion (ก่อน) ใน `plugins_spec.rb`: มี `<input type="search">` ที่มี label; กลุ่ม "Bundled with Kong" และ "Custom"; custom ไม่มีคำอธิบายแสดง `hints.plugins.custom_missing_description` พร้อม path `config/custom_plugins/<name>.yml`
- [ ] **Step 2:** FAIL → ทำ UI (filter ฝั่ง client; ไม่มี JS ทุกแถวยังอยู่) · scope mark ใช้ `.scope` เดิม
- [ ] **Step 3:** PASS · snapshot · detect · Commit `feat(R4.6): searchable plugin catalog with descriptions and scope`

---

### Task R4.7: ฟอร์ม config จาก schema (UI)

**ชั้น:** UI · **ต้องเสร็จก่อน:** R4.6 · **ไฟล์ที่แก้ได้:** `app/views/plugins/new.html.erb` (ขั้น config), `app/views/plugins/_field.html.erb` (create), `app/views/plugins/_secret_field.html.erb` (create), `app/views/plugins/_schema_reference.html.erb` (ลบหลังย้ายไป shared ใน R3.4), `app/javascript/controllers/json_field_controller.js` (create — ใช้ logic parse/ข้อความเดียวกับ `json_editor_controller.js`), `app/helpers/plugins_helper.rb`, `app/assets/tailwind/application.css`, `config/locales/hints.en.yml` (`hints.fields.plugin.*`, `hints.risks.plugin_secret_pr`, `hints.risks.schema_mismatch`), `spec/requests/ui_snapshots_spec.rb`

**คำสั่ง:** `/impeccable shape schema-driven plugin form` → `/impeccable clarify` → `/impeccable harden`

- [ ] **Step 1:** assertion (ก่อน): field ลับเป็น `type="password"` `autocomplete="off"` ไม่มี `value`, มี hint ตัวอย่าง `{vault://env/<plugin>-<field>}`; PR mode มีข้อความ "must be a vault reference or decK placeholder"; เตือน mismatch แสดงชื่อ env/เวอร์ชัน; plugin บน admin path แสดง notice read-only และไม่มีปุ่ม submit; "Advanced: edit as JSON" เป็น `.disclosure`
- [ ] **Step 2:** FAIL → ทำ UI · control ตาม kind: `:enum` select, `:boolean` checkbox, `:list` textarea, `:json` sub-editor; required มีป้าย; default แสดงเป็น placeholder + "Default: …"
- [ ] **Step 3:** PASS · snapshot (rate-limiting, aws-lambda secret, custom plugin, PR mode, mismatch) · detect · ภาพ 390/1280
- [ ] **Step 4:** Commit `feat(R4.7): plugin config form built from the node's schema, secrets masked`

---

### Task R4.8: คำอธิบาย plugin ที่มากับ Kong (UI — microcopy)

**ชั้น:** UI · **ต้องเสร็จก่อน:** R4.2 · **ไฟล์ที่แก้ได้:** `config/locales/hints.en.yml` (`hints.plugins.<name>.summary` ทุกชื่อใน `config/kong_bundled_plugins.yml`, `hints.plugins.custom_missing_description`)

**คำสั่ง:** `/impeccable clarify config/locales/hints.en.yml`

- [ ] **Step 1:** เขียน summary 1 บรรทัดต่อ plugin (สิ่งที่ทำ + ใช้เมื่อไร) · ที่ไม่มั่นใจ → `To Edit:`
- [ ] **Step 2:** spec (เพิ่มใน `spec/services/kong/plugin_catalog_spec.rb`): ทุกชื่อใน `kong_bundled_plugins.yml` มี `hints.plugins.<name>.summary`
- [ ] **Step 3:** Commit `docs(R4.8): one-line descriptions for Kong's bundled plugins`

---

### Task R4.9: ตรวจ flow จริง (verification)

**ชั้น:** — · **ต้องเสร็จก่อน:** R4.1–R4.8

- [ ] `local/dev` (rw): catalog แสดง 43 plugin, ค้นหา "rate" เจอ rate-limiting; สร้าง rate-limiting ระดับ service ด้วยฟอร์ม → review → apply → `curl` เกิน limit ได้ 429
- [ ] สร้าง aws-lambda ด้วย `aws_secret` plaintext (direct) → plan review และ read-model ไม่มีค่า (`grep` DB) → ลบ plugin
- [ ] `local/uat` (pr): plugin ที่มี secret plaintext → ถูกปฏิเสธ; ด้วย `{vault://env/…}` → เข้า changeset; preview YAML มี reference ไม่มี plaintext
- [ ] เปิด config ของ plugin บน admin route → read-only
- [ ] custom plugin: เพิ่ม `config/custom_plugins/<name>.yml` จำลอง (ไม่ต้องติดตั้งใน Kong) → ยืนยันด้วย spec แทน (บันทึกว่าไม่มี custom plugin ใน compose)
- [ ] ภาพหน้าจอ

## เกณฑ์ปิดงาน R4

- [ ] เกณฑ์ใน `R4-plugins.md` (ฉบับแก้ §C5) ครบ พร้อมหลักฐาน
- [ ] migration `kong_schemas` up/down ผ่าน
- [ ] `bundle exec rspec` 0 failures · detect ไม่เพิ่ม · `hints:todo` รายงาน
- [ ] ไม่มีค่าลับของ plugin ใน read-model / plan / audit / YAML / response ของ MCP (`kong_plan` ของ plugin ที่มี secret คืน `[REDACTED]`)
