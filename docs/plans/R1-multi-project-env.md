# R1 — Multiple projects, multiple environments Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** จัด connection เป็น project → env (ชื่อและลำดับตั้งเองต่อ project) โดย rank/apply_mode อยู่ที่ env, env PR mode มาจาก `connections.yml` เท่านั้น, apply_mode ที่ยังไม่กำหนด = เขียนไม่ได้, header บอก project/env ตลอดและ switcher ไปหน้า login ของ env อื่น, MCP อ้าง `project/env`

**Architecture:** ตารางใหม่ `projects` และ `project_envs` เป็นแหล่งเดียวของนโยบาย; `kong_connections` ได้ `project_env_id` (unique) และเก็บ **สำเนา** `env`/`rank`/`apply_mode`/`color_tag`/git settings ที่ `before_validation` คัดลอกจาก env ทุกครั้ง — โค้ดเดิมทุกจุดที่อ่าน `connection.rank`/`apply_mode` จึงไม่ต้องแก้ และ rollback ง่าย · `source` (`registry`/`local`) คุมว่าแก้ใน UI ได้หรือไม่

**Tech Stack:** Rails 8.1 migrations, ActiveRecord validations, RSpec, TypeScript MCP (description เท่านั้น)

**Spec:** `docs/requirements/R1-multi-project-env.md` (+ `design-amendments.md` §C2, §A1), `docs/plans/00-roadmap.md` (Q3–Q8, F1)

## Global Constraints

- `apply_mode` ∈ `direct | pr | NULL`; NULL = ห้ามเขียนทุกเส้นทาง (planner, applier, API) — ห้ามตีความเป็น `direct`
- `pr` ตั้งได้จาก `config/connections.yml` เท่านั้น; UI ไม่มี control ใดตั้งหรือถอด `pr`
- rank: ชื่อ env `dev/sit/uat/prod` (ไม่สนตัวพิมพ์) = 0/1/2/3 บังคับ; ชื่ออื่น = "other" ต้องเลือก 0–3 **ไม่มี default**
- 1 env = 1 connection (`kong_connections.project_env_id` unique)
- ชื่ออ้างอิง = `<project.key>/<env.name>`; key และ env name: `/\A[a-z0-9][a-z0-9-]{0,39}\z/`
- ไม่มี secret ใน `connections.yml`; credential เดิม (`auth_secret`) ต้องอยู่รอด migration โดยไม่ต้องกรอกใหม่
- migration ทุกตัว reversible และมีขั้นตอน rollback ใน `00-roadmap.md`
- ความดังของ UI (violet chrome, retype) ตาม rank เท่านั้น (`KongConnection#env_tone`) ไม่ใช่ตาม `color_tag`

## Review Focus

1. env ชื่อ `Prod` / `PROD` (ตัวพิมพ์ใหญ่) → ต้องได้ rank 3 เหมือน `prod` — test ใน R1.1
2. env "other" ที่สร้างผ่าน `connections.yml` โดยลืมใส่ `rank` → loader ต้องล้มพร้อมชื่อ env ไม่ใช่ข้ามไปเงียบๆ — test ใน R1.4
3. connection ที่ `apply_mode` NULL ถูก MCP `kong_plan` เรียก → 403 ก่อนสร้าง plan — test ใน R1.3
4. แก้ `connections.yml` ย้าย env จาก `pr` เป็น `direct` แล้ว load ใหม่ ขณะมี plan PR ค้าง → plan ค้างต้องถูกปฏิเสธตอน apply (applier อ่าน apply_mode ปัจจุบัน) — test ใน R1.3
5. PAT ที่ผูก connection ไว้ก่อน migration → ยังใช้ได้ และอ้างด้วยชื่อใหม่ `default/<ชื่อเดิม>` — test ใน R1.6

---

## Spec ที่ตกลงแล้ว

- **Project**: `key` (unique, ใช้ในชื่ออ้างอิง), `name` (แสดงผล), `source`, git: `git_repo`, `git_branch`, `git_web_url` (repo แยกต่อ project — Q6), `delete_threshold` (default 3 — ใช้ใน R8), `network_note` (≤ 200 ตัวอักษร เช่น "Reachable from the NONPROD VPN only" — แต่ละ project อยู่คนละ network, ข้อความนี้ต่อท้าย error เครือข่ายทุกที่ ตัดสินรอบ 2)
- **ProjectEnv**: `name`, `position` (ลำดับ, unique ต่อ project), `rank`, `apply_mode` (nullable), `color_tag`, `source`, `git_path`, `deck_extra_paths` (text[] — R8), `select_tags` (text[])
- **Connection**: เป็นของ env เดียว; ฟิลด์เฉพาะเครื่อง (admin_url, TLS, credential_mode, auth, shared_usernames) ยังอยู่ที่ connection
- **registry vs local**: แถวที่ loader สร้าง = `registry` (แก้ใน UI ไม่ได้, badge "From connections.yml"); แถวที่ UI สร้าง = `local` (แก้/ลบได้, badge "Local only"); env `local` ตั้ง apply_mode ได้แค่ `direct` หรือไม่ตั้ง
- **Legacy**: `connections.yml` แบบ list เดิมยังโหลดได้ → project `default`, env name = ชื่อ connection เดิม (เพื่อไม่ชนกันเมื่อมีหลาย connection ใน env เดียว เช่น `dev-readwrite`/`dev-readonly`)
- **Switcher**: header แสดง `Project name` + env chip ปัจจุบัน + รายการ env ของ project ตามลำดับ; คลิก env อื่น → `login_connection_path(conn)`; env ที่ยังไม่มี connection แสดงแต่กดไม่ได้

### `config/connections.yml` รูปแบบใหม่

```yaml
projects:
  - key: project-a
    name: Project A
    git_repo: git@git.example:team/project-a-kong.git
    git_branch: main
    git_web_url: https://git.example/team/project-a-kong/tree/{branch}
    network_note: Reachable from the NONPROD VPN (vpn-nonprod) only
    envs:
      - name: dev
        apply_mode: direct
        admin_url: https://kong-a-dev-admin.internal
      - name: pt            # other → rank ต้องมี
        rank: 1
        apply_mode: direct
        admin_url: https://kong-a-pt-admin.internal
      - name: uat
        apply_mode: pr
        admin_url: https://kong-a-uat-admin-ro.internal
        git_path: uat/kong.yaml
        select_tags: [managed-by-kongctl]
```

## Contract UI ↔ backend

| backend ให้ | รายละเอียด |
|---|---|
| `@projects` (`connections#index`) | `Project.includes(project_envs: :kong_connection).order(:name)`; env เรียงตาม `position` |
| `Project#source`, `ProjectEnv#source` | `"registry"` / `"local"` |
| `Project#network_note`, `KongConnection#network_note` | String หรือ nil (R1.11) |
| `KongConnection#last_status` | เพิ่มค่า `"unreachable"` = เครื่องนี้เข้า network ไม่ได้ (ต่างจาก `"unavailable"` = Kong ตอบ 502/503) (R1.11) |
| `ProjectEnv#rank_kind` | `"known"` / `"other"` |
| `ProjectEnv#write_policy` | `:pr` / `:direct` / `:unset` (สำหรับ label; `:unset` = "Apply mode not set — nothing can be written") |
| `KongConnection#qualified_name` | `"project-a/uat"` |
| `KongConnection#editable_in_ui?` | `project_env.source == "local"` |
| `current_project_envs` (helper_method) | `Array<{env: ProjectEnv, connection: KongConnection \| nil, current: Boolean}>` ของ project ของ connection ที่ login อยู่ ([] ถ้าไม่ได้ login) |
| routes | `resources :projects, param: :key, only: %i[new create edit update]` (R5 เพิ่ม `show`) · `resources :project_envs, only: %i[new create edit update destroy]` (param `project_id` ตอน new/create) · connections new/create รับ `project_env_id` |
| form params ของ env | `name, position, rank, apply_mode (""\|"direct"), color_tag` — `pr` ถูกปฏิเสธ 422 |
| form params ของ connection | `project_env_id, admin_url, verify_ssl, ca_bundle_path, auth_type, credential_mode` (ไม่มี `env`, `apply_mode`, `rank`, `name` — ชื่อมาจาก qualified name) |
| API `GET /api/v1/connections` | `{name: "project/env", project, env, rank, apply_mode (nullable), access_level, credential_mode, kong_version}` |

---

### Task R1.1: `projects` + `project_envs` (backend)

**ชั้น:** backend · **ต้องเสร็จก่อน:** T0, R3.1 · **ไฟล์ที่แก้ได้:**
- Create: `db/migrate/<ts>_create_projects.rb`, `db/migrate/<ts>_create_project_envs.rb`, `app/models/project.rb`, `app/models/project_env.rb`, `spec/models/project_spec.rb`, `spec/models/project_env_spec.rb`, `spec/factories/projects.rb`, `spec/factories/project_envs.rb`
- Modify: `db/schema.rb` (generated)

**Interfaces:**
- `Project` — `has_many :project_envs, -> { order(:position) }, dependent: :restrict_with_error`; `SOURCES = %w[registry local]`; `KEY_FORMAT`
- `ProjectEnv` — `belongs_to :project`; `has_one :kong_connection`; `KNOWN_RANKS = {"dev"=>0,"sit"=>1,"uat"=>2,"prod"=>3}`; `#rank_kind`, `#write_policy`, `#qualified_name`

- [x] **Step 1: test (เขียนก่อน)**

```ruby
# spec/models/project_env_spec.rb
require "rails_helper"

RSpec.describe ProjectEnv do
  let(:project) { create(:project, key: "project-a") }

  it "forces the rank of a known env name, whatever case it is typed in" do
    env = described_class.create!(project: project, name: "Prod", position: 1, rank: 0, apply_mode: nil)
    expect(env).to have_attributes(name: "prod", rank: 3) # name is down-cased before validation
  end

  it "rejects a name that cannot be part of project/env" do
    expect(described_class.new(project: project, name: "pre prod", position: 1, rank: 3)).not_to be_valid
  end

  it "requires an explicit rank for an env name it does not know, with no default" do
    env = described_class.new(project: project, name: "pt", position: 1)
    expect(env).not_to be_valid
    expect(env.errors[:rank]).to be_present
    env.rank = 1
    expect(env).to be_valid
    expect(env.rank_kind).to eq("other")
  end

  it "keeps rank within 0..3" do
    expect(described_class.new(project: project, name: "ps", position: 1, rank: 4)).not_to be_valid
  end

  it "allows apply_mode to be unset and says nothing can be written" do
    env = described_class.create!(project: project, name: "dev", position: 1, apply_mode: nil)
    expect(env.write_policy).to eq(:unset)
  end

  it "never lets a local env be PR mode -- only connections.yml can" do
    env = described_class.new(project: project, name: "uat", position: 1, apply_mode: "pr", source: "local")
    expect(env).not_to be_valid
    expect(env.errors[:apply_mode].join).to match(/connections\.yml/)
  end

  it "orders envs by position and keeps positions unique per project" do
    described_class.create!(project: project, name: "dev", position: 1)
    expect(described_class.new(project: project, name: "sit", position: 1)).not_to be_valid
  end

  it "names itself project/env" do
    env = described_class.create!(project: project, name: "sit", position: 2)
    expect(env.qualified_name).to eq("project-a/sit")
  end
end
```

```ruby
# spec/models/project_spec.rb
require "rails_helper"

RSpec.describe Project do
  it "requires a lower-case key usable in project/env names" do
    expect(build(:project, key: "Project A")).not_to be_valid
    expect(build(:project, key: "project-a")).to be_valid
  end

  it "keeps project keys unique regardless of case" do
    create(:project, key: "project-a")
    expect(build(:project, key: "project-a")).not_to be_valid
  end

  it "defaults the changeset delete threshold to 3" do
    expect(create(:project).delete_threshold).to eq(3)
  end

  it "keeps the network note short enough to sit under an error" do
    expect(build(:project, network_note: "x" * 201)).not_to be_valid
    expect(build(:project, network_note: "Reachable from the NONPROD VPN only")).to be_valid
  end
end
```

- [x] **Step 2:** รัน → FAIL (uninitialized constant)
- [x] **Step 3: migrations**

```ruby
class CreateProjects < ActiveRecord::Migration[8.1]
  def change
    create_table :projects do |t|
      t.citext :key, null: false
      t.string :name, null: false
      t.string :source, null: false, default: "local"
      t.string :git_repo
      t.string :git_branch
      t.string :git_web_url
      t.integer :delete_threshold, null: false, default: 3
      t.string :network_note
      t.timestamps
    end
    add_index :projects, :key, unique: true
  end
end

class CreateProjectEnvs < ActiveRecord::Migration[8.1]
  def change
    create_table :project_envs do |t|
      t.references :project, null: false, foreign_key: true
      t.string :name, null: false
      t.integer :position, null: false
      t.integer :rank, null: false
      t.string :apply_mode            # NULL = not set -> nothing can be written
      t.string :color_tag
      t.string :source, null: false, default: "local"
      t.string :git_path
      t.text :deck_extra_paths, array: true, null: false, default: []
      t.text :select_tags, array: true, null: false, default: []
      t.timestamps
    end
    add_index :project_envs, %i[project_id name], unique: true
    add_index :project_envs, %i[project_id position], unique: true
  end
end
```

- [x] **Step 4:** models ตาม test (`before_validation :normalize_name` (`strip.downcase`) แล้ว `:force_known_rank` ใช้ `KNOWN_RANKS[name]`; `validates :rank, presence: true, inclusion: { in: 0..3 }`; `validate :pr_only_from_registry`; `color_tag` default จาก rank เหมือน `KongConnection#default_color_tag_from_env` เดิม)
- [x] **Step 5:** `bin/rails db:migrate && bin/rails db:rollback STEP=2 && bin/rails db:migrate` สะอาด · PASS · suite 0 failures
- [x] **Step 6:** Commit `feat(R1.1): projects and their ordered envs own rank and apply_mode`

---

### Task R1.2: connection เป็นของ env (backend + backfill)

**ชั้น:** backend · **ต้องเสร็จก่อน:** R1.1 · **ไฟล์ที่แก้ได้:**
- Create: `db/migrate/<ts>_add_project_env_to_kong_connections.rb`, `app/services/kong/legacy_project_backfill.rb`, `spec/services/kong/legacy_project_backfill_spec.rb`
- Modify: `app/models/kong_connection.rb`, `app/models/project_env.rb`, `spec/models/kong_connection_spec.rb`, `spec/factories/kong_connections.rb` (สร้าง project_env ให้อัตโนมัติ; trait `:prod` สร้าง env `prod`)

**Interfaces:**
- `KongConnection belongs_to :project_env` (validation `presence`, DB column nullable จนถึง backfill แล้วเปลี่ยนเป็น `null: false` ในขั้น `up` เดียวกัน)
- `KongConnection#qualified_name`, `#project`, `#editable_in_ui?`
- `before_validation :copy_policy_from_env` คัดลอก `env ← project_env.name`, `rank`, `apply_mode`, `color_tag`, `git_path`, `select_tags`, และจาก project: `git_repo`, `git_branch`, `git_web_url`; และตั้ง `name ← qualified_name`
- ลบ `ENVS`, `RANKS`, `derive_rank_from_env`, `validates :env, inclusion`
- `Kong::LegacyProjectBackfill.call` → สร้าง project `default` (source ตาม: ถ้ามีแถวไหนมาจาก registry ไม่รู้ได้ → `local`) และ env ต่อ connection: `name = parameterize(connection.name)`, `position` เรียงตาม rank แล้วชื่อ, `rank`/`apply_mode`/`color_tag`/git/select_tags จาก connection

- [x] **Step 1: test**

```ruby
# spec/services/kong/legacy_project_backfill_spec.rb
require "rails_helper"

RSpec.describe Kong::LegacyProjectBackfill do
  it "gives every legacy connection its own env in project 'default', keeping its credential" do
    rw = KongConnection.new(name: "dev-readwrite", env: "dev", rank: 0, admin_url: "http://localhost:8001",
      color_tag: "green", apply_mode: "direct", credential_mode: "stored", auth_username: "jakkapat", auth_secret: "pw")
    rw.save!(validate: false)
    ro = KongConnection.new(name: "dev-readonly", env: "dev", rank: 0, admin_url: "http://localhost:8001",
      color_tag: "green", apply_mode: "direct")
    ro.save!(validate: false)

    described_class.call

    expect(rw.reload.project_env.qualified_name).to eq("default/dev-readwrite")
    expect(ro.reload.project_env.qualified_name).to eq("default/dev-readonly")
    expect(rw.project_env.rank).to eq(0)
    expect(rw.auth_secret).to eq("pw")
  end

  it "is idempotent" do
    c = KongConnection.new(name: "uat", env: "uat", rank: 2, admin_url: "http://localhost:8001", color_tag: "orange", apply_mode: "pr")
    c.save!(validate: false)
    2.times { described_class.call }
    expect(ProjectEnv.count).to eq(1)
  end
end
```

```ruby
# spec/models/kong_connection_spec.rb — เพิ่ม
it "takes env, rank, apply_mode and its name from its env, overriding whatever was assigned" do
  env = create(:project_env, name: "ps", rank: 3, apply_mode: "direct", project: create(:project, key: "project-x"))
  connection = create(:kong_connection, project_env: env, rank: 0, apply_mode: "pr", env: "dev")
  expect(connection).to have_attributes(env: "ps", rank: 3, apply_mode: "direct", name: "project-x/ps")
  expect(connection.protected_env?).to be(true)
end

it "allows one connection per env" do
  env = create(:project_env)
  create(:kong_connection, project_env: env)
  expect(build(:kong_connection, project_env: env)).not_to be_valid
end
```

- [x] **Step 2:** FAIL → migration:

```ruby
class AddProjectEnvToKongConnections < ActiveRecord::Migration[8.1]
  def up
    add_reference :kong_connections, :project_env, foreign_key: true, index: { unique: true }
    Kong::LegacyProjectBackfill.call
    change_column_null :kong_connections, :project_env_id, false
  end

  def down
    remove_reference :kong_connections, :project_env, foreign_key: true, index: { unique: true }
  end
end
```
(ตอน `up` เรียก `KongConnection.reset_column_information` ก่อน backfill)

- [x] **Step 3:** implement model + backfill → PASS
- [x] **Step 4:** ทดสอบ migration บนสำเนา DB dev: `pg_dump` → restore เป็น `kong_integration_r1check` → `DATABASE_URL=… bin/rails db:migrate` → ตรวจ connection ครบ + `auth_secret` decrypt ได้ → `db:rollback STEP=1` → `db:migrate` อีกรอบ
- [x] **Step 5:** suite 0 failures (factory ใหม่ทำให้ spec เดิมผ่าน; ถ้า spec เดิมตั้ง `env:`/`rank:` ตรงๆ ให้แก้เป็นผ่าน `project_env` — แก้เฉพาะ setup ไม่แก้ expectation; ถ้าต้องแก้ expectation หยุดถาม)
- [x] **Step 6:** Commit `feat(R1.2): every connection belongs to one project env; legacy rows backfilled into project default`

---

### Task R1.3: apply_mode ที่ยังไม่กำหนดเขียนไม่ได้ (backend)

**ชั้น:** backend · **ต้องเสร็จก่อน:** R1.2 · **ไฟล์ที่แก้ได้:**
- Create: `db/migrate/<ts>_make_kong_connection_apply_mode_nullable.rb`
- Modify: `app/services/kong/change_guardrails.rb`, `app/controllers/api/v1/change_plans_controller.rb`, `app/models/kong_connection.rb` (`validates :apply_mode, inclusion:, allow_nil: true`), `app/controllers/connections_controller.rb` (`new` ไม่ตั้ง `apply_mode: "direct"`), `app/services/kong/connections_config_loader.rb` (ลบ `|| "direct"`), `spec/services/kong/change_guardrails_spec.rb`, `spec/services/kong/change_applier_spec.rb`, `spec/requests/api/v1/change_plans_spec.rb`

- [x] **Step 1: test**

```ruby
# spec/services/kong/change_guardrails_spec.rb — เพิ่ม
it "refuses any write while the env has no apply_mode, even with a read-write credential" do
  connection = create(:kong_connection, project_env: create(:project_env, apply_mode: nil), access_level: "rw")
  expect { described_class.check_write_access!(connection: connection) }
    .to raise_error(Kong::ChangeGuardrails::Violation, /apply mode is not set/i)
end
```

```ruby
# spec/services/kong/change_applier_spec.rb — เพิ่ม
it "refuses a pending plan whose env lost its apply_mode after it was proposed" do
  plan = create(:change_plan, status: "pending", apply_mode: "direct")
  plan.kong_connection.project_env.update!(apply_mode: nil)
  plan.kong_connection.save!
  expect { described_class.new(change_plan: plan.reload, client: nil, actor_username: "a").call }
    .to raise_error(Kong::ChangeGuardrails::Violation, /apply mode is not set/i)
end
```

```ruby
# spec/requests/api/v1/change_plans_spec.rb — เพิ่ม (ภายใต้ describe kong_plan)
it "answers 403 and creates no plan on a connection whose apply_mode is not set" do
  connection = create(:kong_connection, :stored, project_env: create(:project_env, apply_mode: nil),
    admin_url: "https://kong-admin.test", access_level: "rw", auth_secret: "devpassword")
  token = token_for(connection) # helper already defined at the top of this spec file

  expect {
    post api_v1_change_plans_path, params: { connection: connection.name, type: "service", operation: "create",
      attributes: { name: "billing", host: "billing.internal" } }, headers: auth(token)
  }.not_to change(ChangePlan, :count)

  expect(response).to have_http_status(:forbidden)
  expect(response.parsed_body["error"]).to match(/apply mode is not set/i)
  expect(a_request(:any, /kong-admin\.test/)).not_to have_been_made
end
```

- [x] **Step 2:** FAIL → แก้ `check_write_access!`:

```ruby
def self.check_write_access!(connection:)
  if connection.apply_mode.nil?
    raise Violation, "#{connection.qualified_name}: apply mode is not set -- nothing can be written until " \
      "the environment is set to direct (in Kongsole) or pr (in connections.yml)"
  end
  return if connection.apply_mode == "pr"
  return if connection.access_level == "rw"

  raise Violation, "this credential can't write (access_level: #{connection.access_level || 'unknown'})"
end
```

- [x] **Step 3:** migration

```ruby
class MakeKongConnectionApplyModeNullable < ActiveRecord::Migration[8.1]
  def up
    change_column_default :kong_connections, :apply_mode, from: "direct", to: nil
    change_column_null :kong_connections, :apply_mode, true
  end

  def down
    unset = select_values("SELECT name FROM kong_connections WHERE apply_mode IS NULL")
    if unset.any?
      raise ActiveRecord::IrreversibleMigration,
        "set apply_mode on #{unset.join(', ')} first -- rolling back must not turn them into direct"
    end
    change_column_null :kong_connections, :apply_mode, false
    change_column_default :kong_connections, :apply_mode, from: nil, to: "direct"
  end
end
```

- [x] **Step 4:** PASS · migrate/rollback/migrate สะอาด · suite 0 failures
- [x] **Step 5:** Commit `feat(R1.3): an env with no apply_mode cannot be written through any path`

---

### Task R1.4: `connections.yml` แบบ project (backend)

**ชั้น:** backend · **ต้องเสร็จก่อน:** R1.3 · **ไฟล์ที่แก้ได้:** `app/services/kong/connections_config_loader.rb`, `config/connections.yml`, `lib/tasks/kong.rake` (ข้อความ output), `spec/services/kong/connections_config_loader_spec.rb`, `spec/fixtures/connections/*.yml` (create)

**Interfaces:** `Kong::ConnectionsConfigLoader.call(path:) -> Array<KongConnection>`; raise `Kong::ConnectionsConfigLoader::InvalidRegistry` (ข้อความระบุ `project/env` ที่ผิด) — ไม่บันทึกอะไรเลยถ้ามีข้อผิด (transaction)

- [x] **Step 1: fixtures + test**

```yaml
# spec/fixtures/connections/two_projects.yml
projects:
  - key: project-a
    name: Project A
    git_repo: /tmp/project-a.git
    envs:
      - { name: dev, apply_mode: direct, admin_url: "http://localhost:8001" }
      - { name: sit, apply_mode: direct, admin_url: "http://localhost:8011" }
      - { name: uat, apply_mode: pr, admin_url: "http://localhost:8021", git_path: uat/kong.yaml, select_tags: [managed-by-kongctl] }
      - { name: pt, rank: 1, apply_mode: direct, admin_url: "http://localhost:8031" }
      - { name: ps, rank: 3, apply_mode: pr, admin_url: "http://localhost:8041", git_path: ps/kong.yaml, select_tags: [managed-by-kongctl] }
      - { name: prod, apply_mode: pr, admin_url: "https://kong-a-prod-ro.internal", git_path: prod/kong.yaml, select_tags: [managed-by-kongctl] }
  - key: project-x
    name: Project X
    envs:
      - { name: nonprod, rank: 1, apply_mode: direct, admin_url: "http://localhost:8051" }
      - { name: pt, rank: 1, admin_url: "http://localhost:8061" }
      - { name: prod, apply_mode: pr, admin_url: "https://kong-x-prod-ro.internal", git_path: prod/kong.yaml, select_tags: [managed-by-kongctl] }
```

```ruby
# spec/services/kong/connections_config_loader_spec.rb — เพิ่ม
describe "project format" do
  let(:path) { Rails.root.join("spec/fixtures/connections/two_projects.yml") }

  it "creates both projects with their own envs in their own order" do
    described_class.call(path: path)
    expect(Project.find_by!(key: "project-a").project_envs.map(&:name)).to eq(%w[dev sit uat pt ps prod])
    expect(Project.find_by!(key: "project-x").project_envs.map(&:name)).to eq(%w[nonprod pt prod])
  end

  it "marks everything it loads as registry and names connections project/env" do
    described_class.call(path: path)
    expect(KongConnection.pluck(:name)).to include("project-a/ps", "project-x/nonprod")
    expect(ProjectEnv.distinct.pluck(:source)).to eq(%w[registry])
  end

  it "leaves an env without apply_mode unset instead of direct" do
    described_class.call(path: path)
    expect(KongConnection.find_by!(name: "project-x/pt").apply_mode).to be_nil
  end

  it "refuses the whole file when an 'other' env has no rank, naming it" do
    bad = Rails.root.join("tmp/bad_registry.yml")
    File.write(bad, { "projects" => [ { "key" => "p", "name" => "P", "envs" => [ { "name" => "pt", "admin_url" => "http://localhost:1" } ] } ] }.to_yaml)
    expect { described_class.call(path: bad) }.to raise_error(described_class::InvalidRegistry, %r{p/pt.*rank})
    expect(Project.count).to eq(0)
  end

  it "keeps a stored credential when the file is loaded again" do
    described_class.call(path: path)
    KongConnection.find_by!(name: "project-a/dev").update!(credential_mode: "stored", auth_username: "u", auth_secret: "s")
    described_class.call(path: path)
    expect(KongConnection.find_by!(name: "project-a/dev").auth_secret).to eq("s")
  end
end

it "still loads the legacy flat list into project default" do
  described_class.call(path: Rails.root.join("spec/fixtures/connections/legacy.yml"))
  expect(KongConnection.pluck(:name)).to include("default/dev-readwrite")
end
```

- [x] **Step 2:** FAIL → implement (detect `Hash` with `projects:` vs `Array` legacy; ทุกแถวที่ load → `source: "registry"`; upsert project by key, env by (project, name), connection by env; position = index ใน list + 1; env/connection ที่เคยเป็น registry แต่หายไปจากไฟล์ → **ไม่ลบ** ให้พิมพ์เตือนใน rake output)
- [x] **Step 3:** แปลง `config/connections.yml` ของ compose เป็นรูปแบบใหม่: project `local` — env `dev` (rw route), `dev-ro` (`rank: 0`, ro route), `sit`, `uat` (pr) — คงคอมเมนต์อธิบายเดิมทั้งหมด
- [x] **Step 4:** PASS · `bin/rails kong:load_connections` กับ compose พิมพ์ `local/dev`, `local/dev-ro`, `local/sit`, `local/uat`
- [x] **Step 5:** Commit `feat(R1.4): connections.yml groups envs under projects; pr envs live only here`

---

### Task R1.5: จัดการ project/env/connection ใน UI (backend)

**ชั้น:** backend · **ต้องเสร็จก่อน:** R1.4 · **ไฟล์ที่แก้ได้:**
- Create: `app/controllers/projects_controller.rb`, `app/controllers/project_envs_controller.rb`, `app/views/projects/{new,edit,_form}.html.erb`, `app/views/project_envs/{new,edit,_form}.html.erb` (view ตั้งต้นขั้นต่ำ: field + label + error list เท่านั้น), `spec/requests/projects_spec.rb`, `spec/requests/project_envs_spec.rb`
- Modify: `config/routes.rb`, `app/controllers/connections_controller.rb`, `app/views/connections/_form.html.erb` (render field ใหม่ตาม contract เท่านั้น), `app/views/connections/index.html.erb` (loop `@projects` ขั้นต่ำ), `spec/requests/connections_spec.rb`

- [x] **Step 1: test**

```ruby
# spec/requests/project_envs_spec.rb
require "rails_helper"

RSpec.describe "Project envs", type: :request do
  let(:project) { create(:project, key: "project-x", source: "local") }

  it "creates a local direct env with a chosen rank for an 'other' name" do
    post project_envs_path, params: { project_env: { project_id: project.id, name: "nonprod", position: 1, rank: 1, apply_mode: "direct" } }
    expect(ProjectEnv.find_by!(name: "nonprod")).to have_attributes(rank: 1, apply_mode: "direct", source: "local")
  end

  it "refuses pr from the UI" do
    post project_envs_path, params: { project_env: { project_id: project.id, name: "uat", position: 1, apply_mode: "pr" } }
    expect(response).to have_http_status(:unprocessable_entity)
    expect(ProjectEnv.count).to eq(0)
  end

  it "refuses to edit an env that came from connections.yml" do
    env = create(:project_env, project: project, source: "registry", apply_mode: "pr")
    patch project_env_path(env), params: { project_env: { apply_mode: "direct" } }
    expect(response).to have_http_status(:forbidden)
    expect(env.reload.apply_mode).to eq("pr")
  end

  it "refuses to delete an env that still has a connection" do
    env = create(:project_env, project: project)
    create(:kong_connection, project_env: env)
    delete project_env_path(env)
    expect(ProjectEnv.exists?(env.id)).to be(true)
  end
end
```

```ruby
# spec/requests/connections_spec.rb — เพิ่ม
it "never accepts apply_mode, rank or env from the connection form" do
  env = create(:project_env, apply_mode: "direct", rank: 0, source: "local")
  post connections_path, params: { kong_connection: { project_env_id: env.id, admin_url: "http://localhost:8001",
    credential_mode: "session", apply_mode: "pr", rank: 3, env: "prod" } }
  expect(KongConnection.last).to have_attributes(apply_mode: "direct", rank: 0)
end

it "refuses to edit a registry connection" do
  env = create(:project_env, source: "registry")
  connection = create(:kong_connection, project_env: env)
  patch connection_path(connection), params: { kong_connection: { admin_url: "http://localhost:9999" } }
  expect(response).to have_http_status(:forbidden)
end
```

- [x] **Step 2:** FAIL → implement ตาม contract (strong params ไม่มี `apply_mode: "pr"`: ถ้าค่าเป็น `"pr"` → 422 พร้อม error "PR mode is set in config/connections.yml"; registry → 403 + flash)
- [x] **Step 3:** PASS · suite 0 failures
- [x] **Step 4:** Commit `feat(R1.5): create and edit local projects, direct envs and their connection in the UI`

---

### Task R1.6: API และ MCP อ้าง `project/env` (backend)

**ชั้น:** backend · **ต้องเสร็จก่อน:** R1.2 · **ไฟล์ที่แก้ได้:** `app/controllers/api/v1/base_controller.rb`, `app/controllers/api/v1/connections_controller.rb`, `mcp/src/tools.ts` (description), `mcp/src/tools.test.ts`, `mcp/README.md`, `spec/requests/api/v1/connections_spec.rb` (create ถ้าไม่มี), `spec/requests/api/v1/entities_spec.rb`

- [x] **Step 1: test**

```ruby
# spec/requests/api/v1/connections_spec.rb
require "rails_helper"

RSpec.describe "API connections", type: :request do
  it "lists connections by project/env with project and env apart" do
    env = create(:project_env, name: "uat", apply_mode: "pr", project: create(:project, key: "project-a"))
    connection = create(:kong_connection, :stored, project_env: env)
    pat, raw = PersonalAccessToken.issue!(operator: "o", issued_by_username: "u", connection_ids: [ connection.id ])

    get api_v1_connections_path, headers: { "Authorization" => "Bearer #{raw}" }

    expect(response.parsed_body["data"]).to eq([ {
      "name" => "project-a/uat", "project" => "project-a", "env" => "uat", "rank" => 2, "apply_mode" => "pr",
      "access_level" => nil, "credential_mode" => "stored", "kong_version" => nil } ])
  end

  it "does not resolve a bare env name, which would be ambiguous across projects" do
    env = create(:project_env, name: "uat", apply_mode: "pr", project: create(:project, key: "project-a"))
    connection = create(:kong_connection, :stored, project_env: env)
    _pat, raw = PersonalAccessToken.issue!(operator: "o", issued_by_username: "u", connection_ids: [ connection.id ])

    get api_v1_entities_path, params: { connection: "uat", type: "service" }, headers: { "Authorization" => "Bearer #{raw}" }

    expect(response).to have_http_status(:unauthorized)
    expect(response.parsed_body["error"]).to include("project/env")
  end

  it "keeps a token issued before the migration working under the new name" do
    connection = create(:kong_connection, :stored, project_env: create(:project_env, name: "dev-readwrite",
      rank: 0, project: create(:project, key: "default")))
    _pat, raw = PersonalAccessToken.issue!(operator: "o", issued_by_username: "u", connection_ids: [ connection.id ])

    get api_v1_entities_path, params: { connection: "default/dev-readwrite", type: "service" },
      headers: { "Authorization" => "Bearer #{raw}" }

    expect(response).to have_http_status(:ok)
  end
end
```

- [x] **Step 2:** FAIL → `current_pat_connection` ใช้ `find_by(name: params[:connection])` ต่อไปได้ เพราะ `name` = qualified name แล้ว (R1.2) — เพิ่มการปฏิเสธชื่อที่ไม่มี `/` ด้วยข้อความ "use project/env"
- [x] **Step 3:** MCP: ทุก `connection: z.string()` → `.describe('Connection as "project/env", e.g. "project-a/uat" (required, no default)')` · test ใน `tools.test.ts` ตรวจว่า description มี `project/env`
- [x] **Step 4:** PASS (rspec + vitest) · Commit `feat(R1.6): API and MCP name connections project/env`

---

### Task R1.7: ข้อมูล switcher (backend)

**ชั้น:** backend · **ต้องเสร็จก่อน:** R1.2 · **ไฟล์ที่แก้ได้:** `app/controllers/application_controller.rb`, `spec/requests/connection_switcher_spec.rb` (create)

- [x] **Step 1: test**

```ruby
require "rails_helper"

RSpec.describe "Connection switcher data", type: :request do
  it "lists the logged-in project's envs in order, marking the current one and envs with no connection" do
    project = create(:project, key: "project-a")
    dev = create(:project_env, project: project, name: "dev", position: 1)
    create(:project_env, project: project, name: "sit", position: 2)
    uat = create(:project_env, project: project, name: "uat", position: 3)
    current = create(:kong_connection, project_env: dev, admin_url: "https://kong.test")
    create(:kong_connection, project_env: uat)
    sign_in_to(current) # helper: WebMock stubs as in spec/requests/plugins_spec.rb

    get health_path
    rows = controller.send(:current_project_envs)
    expect(rows.map { |r| [ r[:env].name, r[:connection].present?, r[:current] ] })
      .to eq([ [ "dev", true, true ], [ "sit", false, false ], [ "uat", true, false ] ])
  end
end
```
(สร้าง `spec/support/sign_in_helper.rb` — `module SignInHelper; def sign_in_to(connection, access: :rw, username: "alice")` — stub `GET /`, probe `PATCH #{Kong::AccessProbe::PROBE_PATH}` (404 `Not found` = rw, 404 `no Route matched` = ro), `GET /consumers/<username>`, `GET /routes` แบบเดียวกับ `plugins_spec.rb#sign_in` แล้ว `post login_connection_path`; include ใน `rails_helper` สำหรับ `type: :request`)

- [x] **Step 2:** FAIL → implement → PASS · Commit `feat(R1.7): the header knows the current project's envs`

---

### Task R1.8: หน้า Connections จัดตาม project (UI)

**ชั้น:** UI · **ต้องเสร็จก่อน:** R1.5, R1.11, R3.4 · **ไฟล์ที่แก้ได้:** `app/views/connections/index.html.erb`, `app/views/connections/_project.html.erb` (create), `app/views/connections/_env_row.html.erb` (create), `app/helpers/application_helper.rb` (label helper: `write_policy_label`, `rank_label`, `source_badge`), `app/assets/tailwind/application.css`, `config/locales/hints.en.yml`, `spec/requests/ui_snapshots_spec.rb`, `spec/requests/consistency_spec.rb` (assertion)

**คำสั่ง:** `/impeccable layout app/views/connections/index.html.erb` → `/impeccable onboard` (empty state: ไม่มี project / project ไม่มี env) → `/impeccable clarify`

- [x] **Step 1:** assertion (ก่อน): หน้า index แสดงชื่อ project เป็น heading, env ตาม `position`, env ที่ `apply_mode` nil แสดง `write_policy_label(:unset)`, badge `Local only` / `From connections.yml`
- [x] **Step 2:** FAIL → ทำ UI: ต่อ project หนึ่ง section (heading + git repo แบบ mono + `network_note` ถ้ามี), สถานะ `unreachable` แสดงเป็น "Unreachable from this machine" ต่างจาก `unavailable`, แถว env: env chip (quiet/violet ตาม rank), rank label (`Dev`/`SIT`/`UAT`/`Prod` หรือ `Other · rank 1`), policy tag, สถานะ, ปุ่ม `Log in` (`.btn-secondary`), `Edit`/`Remove` เฉพาะ local · ปุ่มหลักหนึ่งปุ่ม: "New project"
- [x] **Step 3:** PASS · snapshot `connections-index-projects` · detect
- [x] **Step 4:** Commit `feat(R1.8): connections are grouped by project, envs in each project's own order`

**เกณฑ์ detect:** ไม่มี finding หลักเพิ่มจาก baseline · 390px ไม่มี horizontal scroll

---

### Task R1.9: ฟอร์ม project / env / connection (UI)

**ชั้น:** UI · **ต้องเสร็จก่อน:** R1.5, R1.8, R1.11 · **ไฟล์ที่แก้ได้:** `app/views/projects/*`, `app/views/project_envs/*`, `app/views/connections/_form.html.erb`, `app/views/connections/{new,edit,show}.html.erb`, `app/javascript/controllers/env_rank_controller.js` (create), `app/assets/tailwind/application.css`, `config/locales/hints.en.yml`, `spec/requests/ui_snapshots_spec.rb`

**คำสั่ง:** `/impeccable shape project and env forms` → `/impeccable clarify` → `/impeccable harden`

- [x] **Step 1:** env form: ช่อง name; ถ้าชื่อเป็น dev/sit/uat/prod แสดง "Rank N (fixed for this name)" ไม่มี select; ชื่ออื่นแสดง select rank ที่ **ไม่มีค่าเลือกไว้** (`include_blank: "Choose how careful to be…"`, `required`) — `env_rank_controller.js` สลับทันทีที่พิมพ์ (fallback no-JS: server validation แสดง error); apply_mode select: `Not set (read only)` / `Direct apply`; คำอธิบายว่า PR mode ตั้งใน `connections.yml` พร้อมตัวอย่าง YAML
- [x] **Step 1b:** project form: ช่อง `network_note` พร้อม hint และตัวอย่าง "Reachable from the NONPROD VPN only" (registry แสดงอ่านอย่างเดียว)
- [x] **Step 2:** connection form: เลือก env (grouped by project), admin_url, TLS, credential_mode — hint ทุก field
- [x] **Step 3:** registry rows: หน้า show แสดงค่าแบบอ่านอย่างเดียว + "Edit this in config/connections.yml"
- [x] **Step 4:** snapshot + detect · Commit `feat(R1.9): forms for local projects, envs and connections with hints`

---

### Task R1.10: header + switcher (UI)

**ชั้น:** UI · **ต้องเสร็จก่อน:** R1.7, R1.8 · **ไฟล์ที่แก้ได้:** `app/views/layouts/application.html.erb`, `app/views/shared/_env_switcher.html.erb` (create), `app/helpers/application_helper.rb` (`env_badge` แสดง `project name · env`), `app/assets/tailwind/application.css`, `config/locales/hints.en.yml`, `spec/requests/accessibility_spec.rb` (assertion), `spec/requests/ui_snapshots_spec.rb`

**คำสั่ง:** `/impeccable shape header env switcher` → `/impeccable adapt` (390px: 3 แถวสูงสุดตาม `UI-DESIGN.md` §Topbar targets) → `/impeccable harden`

- [x] **Step 1:** assertion (ก่อน): header มีชื่อ project + env ของ connection ปัจจุบัน; switcher เป็น `<nav aria-label="Environments of <project>">` มี link ต่อ env ที่มี connection → `login_connection_path`, env ปัจจุบัน `aria-current="page"`, env ไม่มี connection เป็น `<span aria-disabled="true">`
- [x] **Step 2:** FAIL → ทำ UI (native `<details>` disclosure หรือแถว chip; ต้องใช้คีย์บอร์ดได้; ความดังตาม rank เดิม)
- [x] **Step 3:** PASS · snapshot 390x844 + 1280 · detect
- [x] **Step 4:** Commit `feat(R1.10): header shows project and env; the switcher lists the project's envs`

---

### Task R1.11: เครือข่ายของแต่ละ project — `network_note` + สถานะ unreachable (backend)

**ชั้น:** backend · **ต้องเสร็จก่อน:** R1.5, R3.2 · **ไฟล์ที่แก้ได้:** `app/models/project.rb`, `app/models/kong_connection.rb` (`STATUSES` เพิ่ม `"unreachable"`, `delegate :network_note`), `app/services/kong/connection_login.rb`, `app/services/kong/connections_config_loader.rb`, `app/controllers/application_controller.rb` (`explain_error(e)` = `Kong::ErrorExplanation.for(e, network_note: current_connection&.network_note)` แล้วให้ทุก controller ใช้ตัวนี้แทนการเรียกตรง), `app/controllers/sessions_controller.rb`, `app/controllers/entities_controller.rb`, `app/controllers/plugins_controller.rb`, `app/controllers/projects_controller.rb` (permit `network_note` เฉพาะ local), `app/views/projects/_form.html.erb` (field ขั้นต่ำ), `spec/services/kong/connection_login_spec.rb`, `spec/services/kong/connections_config_loader_spec.rb`, `spec/requests/sessions_spec.rb`, `spec/fixtures/connections/two_projects.yml`

**ทำไม:** แต่ละ project ใช้คนละ network (ตัดสินรอบ 2 ข้อ 4) — ผู้ใช้ต้องรู้ทันทีว่า "เข้าไม่ถึงเพราะยังไม่ต่อ VPN ของ project นี้" ไม่ใช่ "Kong ล่ม"

- [x] **Step 1: test**

```ruby
# spec/services/kong/connection_login_spec.rb — เพิ่ม
it "records a Kong this machine cannot reach as unreachable, not unavailable" do
  connection = create(:kong_connection, admin_url: "https://kong-a-uat.internal")
  stub_request(:get, "https://kong-a-uat.internal/")
    .to_raise(Faraday::ConnectionFailed.new(SocketError.new("getaddrinfo: Name or service not known")))
  described_class.new(connection: connection, username: "a", secret: "b").call
  expect(connection.reload.last_status).to eq("unreachable")
end

it "still records a 502 from the loopback service as unavailable" do
  connection = create(:kong_connection, admin_url: "https://kong.test")
  stub_request(:get, "https://kong.test/").to_return(status: 502, body: "{}")
  described_class.new(connection: connection, username: "a", secret: "b").call
  expect(connection.reload.last_status).to eq("unavailable")
end
```

```ruby
# spec/requests/sessions_spec.rb — เพิ่ม
it "adds the project's network note when the login cannot reach Kong" do
  project = create(:project, network_note: "Reachable from the NONPROD VPN only")
  connection = create(:kong_connection, admin_url: "https://kong-a-uat.internal", project_env: create(:project_env, project: project))
  stub_request(:get, "https://kong-a-uat.internal/").to_raise(Faraday::TimeoutError.new("execution expired"))
  post login_connection_path(connection), params: { username: "a", password: "b" }
  expect(response.body).to include(I18n.t("hints.errors.network_timed_out.title"), "Reachable from the NONPROD VPN only")
end
```

```ruby
# spec/services/kong/connections_config_loader_spec.rb — เพิ่ม
it "reads network_note per project" do
  described_class.call(path: Rails.root.join("spec/fixtures/connections/two_projects.yml"))
  expect(Project.find_by!(key: "project-a").network_note).to eq("Reachable from the NONPROD VPN only")
end
```

- [x] **Step 2:** FAIL → เพิ่ม `network_note: Reachable from the NONPROD VPN only` ให้ project-a ใน fixture → implement → PASS
- [x] **Step 3:** suite 0 failures · Commit `feat(R1.11): each project says which network reaches it; unreachable is told apart from Kong being down`

---

### Task R1.12: ตรวจ flow จริง (verification)

**ชั้น:** — · **ต้องเสร็จก่อน:** R1.1–R1.11

- [ ] โหลด `spec/fixtures/connections/two_projects.yml` เข้า DB dev สำเนา (หรือเพิ่มชั่วคราวใน compose) → หน้า Connections แสดง ProjectA 6 env, ProjectX 3 env ตามลำดับ
- [ ] login `local/dev` → header แสดง `Local · dev`; switcher มี dev, dev-ro, sit, uat; คลิก uat → หน้า login ของ uat (violet)
- [ ] สร้าง project local + env `nonprod` (rank ต้องเลือก) + connection → login ได้; ตั้ง apply_mode = Not set → ปุ่มเขียนหาย, API `kong_plan` 403
- [ ] `bin/rails db:rollback STEP=4` → `db:migrate` บน DB สำเนา สำเร็จ (ถ้ามี env ไม่กำหนด apply_mode rollback ต้องปฏิเสธพร้อมรายชื่อ)
- [ ] MCP: `kong_connections` คืน `local/dev`; `kong_search` ด้วย `connection: "dev"` → error บอกให้ใช้ `project/env`
- [ ] เครือข่าย: สร้าง connection local ชี้ `https://kong.nonexistent.invalid` ใน project ที่มี `network_note` → login แสดง `network_dns_failed` + note, หน้า Connections แสดง "Unreachable from this machine"; `docker compose stop kong-1 kong-2` แล้ว login `local/dev` → `network_refused` (ไม่ใช่ "Admin API down"); start กลับ
- [ ] ภาพหน้าจอ 390/1280 ของ connections, env form, header

### ผลตรวจ R1.12 (2026-09-25, cloud session — ไม่มี Docker/compose)

- [x] โหลด `two_projects.yml` → หน้า Connections แสดง Project A 6 env, Project X 3 env ตามลำดับ (snapshot `connections-index-projects`, consistency_spec)
- [x] migration 4 ตัว: up → rollback STEP=4 → up บน DB scratch (test env) ที่มีแถว legacy — สำเร็จ, credential อยู่ครบ, ชื่อคงเป็น `default/<ชื่อเดิม>`
  (เจอบั๊ก 2 จุดระหว่างตรวจและแก้แล้ว: env ซ้ำเมื่อ rollback 1 ขั้นแล้ว migrate ใหม่ · ชื่อกลายเป็น `default/default-…` หลัง rollback ทั้ง 4)
- [x] rollback ปฏิเสธพร้อมรายชื่อเมื่อมี connection ที่ apply_mode ว่าง
- [x] API/MCP: `kong_connections` คืน `project/env`; ชื่อไม่มี `/` → 401 บอกให้ใช้ `project/env` (request spec + vitest)
- [x] credential: `log_filtering_spec` ผ่าน · `grep "Basic " log/test.log` เจอเฉพาะ fixture `"Basic abc"` · API connections ไม่มี `auth_secret` (spec เทียบ hash ตรงตัว)
- [ ] **ต้องทำบนเครื่องที่มี compose:** login `local/dev` + switcher → uat; สร้าง project/env `nonprod` + connection แล้ว login;
  ตั้ง apply_mode = Not set แล้ว `kong_plan` ต้อง 403; `https://kong.nonexistent.invalid` → `network_dns_failed` + note;
  `docker compose stop kong-1 kong-2` → `network_refused`; ภาพหน้าจอจากแอปจริง (ตอนนี้มีจาก snapshot)
  → ทำแล้วบนเครื่อง compose ดูข้างล่าง

### ผลตรวจ R1.12 บนเครื่องที่มี compose (2026-09-25, Ruby 3.4.8, Kong 3.7.1 × 2 node, Edge headless ผ่าน playwright-core)

- [x] login `local/dev` → header `Local · dev`; switcher `<nav aria-label="Environments of Local">` มี dev (`aria-current="page"`), dev-ro (`Other · rank 0`), sit, UAT;
  เปิดด้วยคีย์บอร์ด (Enter) ได้; คลิก UAT → `/connections/8/login` topbar `env-uat` (`--env: #8a3b86`)
- [x] สร้าง project `r1check` (network_note "Reachable from the NONPROD VPN only") + env `nonprod` ผ่าน UI: พิมพ์ `uat` → "Rank 2, fixed for this name." select ถูกปิด;
  พิมพ์ `nonprod` → select rank ว่าง + `required`; ส่งแบบไม่เลือก rank (ถอด `required` ฝั่ง browser) → server ROLLBACK ไม่สร้าง env ·
  apply_mode มีแค่ `Not set (read only)` / `Direct apply`
- [x] connection `r1check/nonprod` → `http://localhost:8001` (UI สร้าง `http://` ได้เฉพาะ localhost ตาม `admin_url_must_be_https_unless_localhost`;
  route loopback ต้องใช้ Host `kong-admin.internal` จึงชี้ route ไม่ได้จาก UI) · login (session mode) สำเร็จ
- [x] apply_mode = Not set → หน้า connection แสดง "Apply mode not set — nothing can be written"; ส่งฟอร์ม New upstream →
  alert "r1check/nonprod: apply mode is not set -- nothing can be written until …" (ไม่มีอะไรถึง Kong)
- [x] API จริงด้วย PAT: `kong_connections` → `r1check/nonprod` (ไม่มี `auth_secret`); `kong_plan` → **403** ข้อความเดียวกับข้างบน;
  `connection=nonprod` → 401 "is not a project/env name"; connection ที่ PAT ไม่ได้ผูก → 401 · revoke PAT แล้ว
- [x] DNS: `r1check/broken` → `https://kong.nonexistent.invalid` → login แสดง `network_dns_failed` (cause + next step) + "Reachable from the NONPROD VPN only";
  หน้า Connections แสดง "Unreachable from this machine"
- [x] `docker stop` kong-1 + kong-2 → login `local/dev` แสดง `network_refused` ไม่ใช่ "Admin API down"; row แสดง "Unreachable from this machine" ·
  start กลับ healthy, admin route 200, login ใหม่ → Ok
- [x] migration บนสำเนา DB dev (`pg_dump` → `kong_integration_r1check`, 10 connection, 2 env apply_mode ว่าง):
  rollback STEP=4 → ปฏิเสธ "set apply_mode on r1check/nonprod, r1check/broken first" ไม่ revert อะไร ·
  ตั้ง apply_mode แล้ว rollback STEP=4 → สำเร็จ · migrate → **ปฏิเสธ** `LegacyProjectBackfill::ConflictingRepos` (ดูข้อค้าง 3) ·
  ทำให้ git_repo ของ PR ทั้งสองเท่ากันบนสำเนา → migrate สำเร็จ ชื่อเป็น `default/<เดิม>` เช่น `default/local-dev` · drop สำเนาแล้ว
- [x] ภาพหน้าจอ 390 + 1280 จากแอปจริง: connections, header + switcher, login uat, project form, env form, entities (unset), write refused,
  login dns/refused — แนบในรายงาน ไม่ commit · 390px ไม่มี horizontal scroll ในหน้าของ R1
- [x] `bundle exec rspec` **1033 examples, 0 failures** (Ruby 3.4.8) · MCP vitest **30/30**
- [x] credential: `log/development.log` และ stdout ของ server ไม่มี `Authorization` / `Basic <b64>` / password; มีแค่ `token_prefix` + digest ของ PAT
- [x] detect บน snapshot: **59 findings บน 40 หน้า** (R3 ปิดที่ 46 บน 34) · หน้าที่มีทั้งสองรอบ 46 → 43 ·
  หน้าใหม่ของ R1 = 16 (cramped-padding 14, side-tab 1 ที่ `header-switcher`, flat-type-hierarchy 1 ที่ `connection-show-registry`)
- [x] `bin/rails hints:todo` เหลือ 2 (`errors.forbidden.next_step`, `errors.upstream_unavailable.next_step`) — ของ R3.7 ไม่มี key ใหม่ของ R1
- [x] เก็บกวาด DB dev: ลบ project `r1check` (env `nonprod`, `broken`), connection 2 ตัว และ PAT `r1.12 check` (revoke แล้ว) ใน transaction เดียว ·
  ไม่มี audit event / change plan ผูกอยู่ · หลังลบไม่มี connection ที่ apply_mode ว่าง (`db:rollback` ไม่ถูกบล็อก)

**ข้อค้าง (รอเจ้าของงานตัดสิน):**

1. **"ปุ่มเขียนหาย" ไม่มี task ไหนทำ** — R1.12 คาดไว้แต่ R1.3 ปิดที่ backend เท่านั้น · `entities/index` แสดง "New upstream" / "New global plugin" /
   "New certificate" และ `entities/show` แสดง Edit / Add plugin / Add target ทุกกรณี (ไม่ดู apply_mode และไม่ดู `read_only?`) · การเขียนถูกปฏิเสธถูกต้องทุกทาง
2. **แก้ env ที่มี connection แล้วใน UI ไม่ได้** — `_env_row` แสดง Edit ของ connection เท่านั้น ไม่มีลิงก์ไป `edit_project_env_path` ที่ไหนเลย
   → เปลี่ยน apply_mode / rank / สีของ env ที่ต่อแล้วต้องพิมพ์ URL `/project_envs/:id/edit` เอง (ข้อ R1.12 ทำผ่าน URL ตรง)
3. **migrate ใหม่หลัง rollback ทั้ง 4 ล้มเมื่อมี PR connection หลาย repo** — ข้อความบอก "split them into projects in config/connections.yml before migrating"
   แต่ตอนนั้น `kong:load_connections` ใช้ไม่ได้ (`column kong_connections.project_env_id does not exist`) · Postgres ถอย migration นั้นให้ ไม่เสียข้อมูล ·
   เครื่องนี้เจอเพราะ `default/uat` กับ `local/uat` ชี้ `storage/config_repos/uat.git` คนละ checkout (main กับ worktree ใช้ DB dev เดียวกัน)
4. **login connection `stored` ใน development ไม่ได้บนเครื่องนี้** — ไม่มี `config/master.key` → `ActiveRecord::Encryption::Errors::Configuration` (500)
   · เป็นเรื่องสภาพแวดล้อม (T0.4 แก้เฉพาะ test) · ข้อ R1.12 ใช้ session mode แทนตอน login และสลับเป็น stored ตอนออก PAT
5. นอก R1: หน้า Health ที่ 390px เลื่อนแนวนอนได้ถึง 889px เพราะ `<span class="sr-only">Actions</span>` (absolute) หลุดจาก `.overflow-x-auto` — มีตั้งแต่ `682cb0c`
6. นอก R1: หน้า login ที่ 390px ตัด "PR mode" กลางคำ เพราะ `break-all` ครอบทั้งบรรทัด admin URL + apply mode

**คำตัดสินของเจ้าของงาน (2026-09-25):**

| ข้อ | คำตัดสิน | ผลใน plan |
|---|---|---|
| 1 | เพิ่ม task | R1.13 (backend) + R1.14 (UI) |
| 2 | เพิ่ม task | R1.15 (UI) |
| 3 | (ก) แก้ข้อความให้ทำตามได้จริง | R1.16 (backend) |
| 4 | จดไว้ก่อน ยังไม่ทำ | `00-roadmap.md` §งานต่อที่รอ |
| 5–6 | นอก R1 ยังไม่ทำ | — |

หลัง R1.13–R1.16 ต้องรัน R1.17 (ตรวจซ้ำเฉพาะส่วนที่เปลี่ยน) ก่อนปิด R1

---

### Task R1.13: นโยบายการเขียนของ connection เป็นที่เดียว + controller ปฏิเสธก่อนเปิดฟอร์ม (backend)

**ชั้น:** backend · **ต้องเสร็จก่อน:** R1.3 · **ไฟล์ที่แก้ได้:** `app/models/kong_connection.rb`, `app/services/kong/change_guardrails.rb`, `app/controllers/application_controller.rb`, `app/controllers/entities_controller.rb`, `app/controllers/plugins_controller.rb`, `spec/models/kong_connection_spec.rb`, `spec/services/kong/change_guardrails_spec.rb`, `spec/requests/entities_spec.rb`, `spec/requests/plugins_spec.rb`

**ทำไม:** ข้อค้าง 1 — ปุ่มเขียนแสดงทุกกรณี แล้วค่อยถูกปฏิเสธตอนส่ง · UI (R1.14) ต้องมีคำตอบเดียวที่ตรงกับ `check_write_access!` ไม่ใช่เขียนเงื่อนไขเองใน view

- [ ] **Step 1: test**

```ruby
# spec/models/kong_connection_spec.rb — เพิ่ม
describe "#write_block_reason" do
  def connection_for(apply_mode:, access_level:)
    create(:kong_connection, project_env: create(:project_env, apply_mode: apply_mode), access_level: access_level)
  end

  it { expect(connection_for(apply_mode: nil, access_level: "rw").write_block_reason).to eq(:apply_mode_unset) }
  it { expect(connection_for(apply_mode: "direct", access_level: "ro").write_block_reason).to eq(:read_only) }
  it { expect(connection_for(apply_mode: "direct", access_level: nil).write_block_reason).to eq(:read_only) }
  it { expect(connection_for(apply_mode: "direct", access_level: "rw").write_block_reason).to be_nil }
  it { expect(connection_for(apply_mode: "pr", access_level: "ro").write_block_reason).to be_nil } # PR เขียนลง git ไม่ใช่ Kong
end
```

```ruby
# spec/services/kong/change_guardrails_spec.rb — เพิ่ม
it "refuses exactly when the connection says writing is blocked" do
  [ [ nil, "rw" ], [ "direct", "ro" ], [ "direct", "rw" ], [ "pr", "ro" ] ].each do |mode, access|
    connection = create(:kong_connection, project_env: create(:project_env, apply_mode: mode), access_level: access)
    check = -> { described_class.check_write_access!(connection: connection) }
    connection.write_block_reason ? expect(&check).to(raise_error(described_class::Violation)) : expect(&check).not_to(raise_error)
  end
end
```

```ruby
# spec/requests/entities_spec.rb — เพิ่ม (Kong ไม่มี stub สำหรับการเขียน: ถ้ามีการเรียก WebMock จะทำให้ fail)
context "when the env's apply mode is not set" do
  let(:connection) { create(:kong_connection, project_env: create(:project_env, apply_mode: nil)) }
  before { sign_in_to(connection) }

  it "sends new/edit/delete back to the list with the reason instead of opening a form" do
    get new_entity_path(type: "upstream")
    expect(response).to redirect_to(entities_path(type: "upstream"))
    expect(flash[:alert]).to include("apply mode is not set")
  end
end
# plugins_spec.rb: GET new_plugin_path → redirect entities_path(type: "plugin") + alert เดียวกัน
```

- [ ] **Step 2:** FAIL → implement:
  - `KongConnection#write_block_reason` → `:apply_mode_unset` / `:read_only` / `nil` (กติกาเดียวกับ `check_write_access!` เดิม)
  - `ChangeGuardrails.check_write_access!` เรียก `write_block_reason` แล้ว raise ข้อความเดิมทุกตัวอักษร (spec เดิมต้องผ่านโดยไม่แก้)
  - `ApplicationController`: `helper_method :write_block_reason` (ของ `current_connection`, `nil` ถ้าไม่ได้ login) และ `require_writable!` ที่ redirect ไป list ของ type นั้นพร้อม `flash[:alert]` = ข้อความของ guardrail
  - `before_action :require_writable!` ใน `EntitiesController` (`new create edit update destroy`) และ `PluginsController` (`new create`)
- [ ] **Step 3:** PASS · suite 0 failures · Commit `feat(R1.13): one write policy per connection; write forms refuse before they open`

---

### Task R1.14: ซ่อนปุ่มเขียนเมื่อ env เขียนไม่ได้ พร้อมบอกเหตุผล (UI)

**ชั้น:** UI · **ต้องเสร็จก่อน:** R1.13, R3.4 · **ไฟล์ที่แก้ได้:** `app/views/entities/index.html.erb`, `app/views/entities/show.html.erb`, `app/views/change_plans/show.html.erb` (เฉพาะปุ่ม Apply / Push branch), `app/views/shared/_write_blocked.html.erb` (create), `app/assets/tailwind/application.css`, `config/locales/hints.en.yml` (`hints.risks.write_blocked.apply_mode_unset`, `hints.risks.write_blocked.read_only`), `spec/requests/consistency_spec.rb` (assertion), `spec/requests/ui_snapshots_spec.rb`

**คำสั่ง:** `/impeccable clarify write-blocked notice` → `/impeccable harden`

- [ ] **Step 1:** assertion (ก่อน): เมื่อ `write_block_reason` ไม่ใช่ nil — `entities/index` ไม่มี "New upstream" / "New global plugin" / "New certificate" / "New CA certificate";
  `entities/show` ไม่มี Edit / Delete / Add plugin / Add target / Add SNI; `change_plans/show` ไม่มีปุ่ม Apply / Push branch;
  ทุกหน้านั้นมี notice เดียวที่ใช้ข้อความจาก `hints.risks.write_blocked.<reason>` · เมื่อ `nil` ทุกปุ่มยังอยู่ครบ (กันการซ่อนเกิน)
- [ ] **Step 2:** FAIL → ทำ UI: notice เงียบ (ไม่ใช่ danger) บอกว่า "ทำไมเขียนไม่ได้" + "แก้อย่างไร"
  (`apply_mode_unset` → ตั้งเป็น Direct apply ที่หน้า Connections หรือ PR mode ใน `config/connections.yml`; `read_only` → login ด้วย credential ที่เขียนได้) · ปุ่มอ่านอย่างเดียว (Sync now, Filter, Expiring soon) ไม่แตะ
- [ ] **Step 3:** PASS · snapshot `entities-index-write-blocked`, `entity-show-write-blocked` · detect ไม่เพิ่ม · 390px ไม่มี horizontal scroll
- [ ] **Step 4:** Commit `feat(R1.14): write buttons stay hidden where nothing can be written, and the page says why`

---

### Task R1.15: แก้ env ที่มี connection แล้วได้จากหน้า Connections (UI)

**ชั้น:** UI · **ต้องเสร็จก่อน:** R1.8, R1.9 · **ไฟล์ที่แก้ได้:** `app/views/connections/_env_row.html.erb`, `app/views/connections/show.html.erb`, `app/assets/tailwind/application.css`, `config/locales/hints.en.yml`, `spec/requests/consistency_spec.rb` (assertion), `spec/requests/accessibility_spec.rb` (assertion), `spec/requests/ui_snapshots_spec.rb`

**ทำไม:** ข้อค้าง 2 — env ที่ต่อแล้วเปลี่ยน apply_mode / rank / สีไม่ได้ถ้าไม่พิมพ์ URL เอง

**คำสั่ง:** `/impeccable layout app/views/connections/_env_row.html.erb` → `/impeccable harden`

- [ ] **Step 1:** assertion (ก่อน): แถว env `source: "local"` ที่มี connection มีลิงก์ไป `edit_project_env_path(env)` และลิงก์ไป `edit_connection_path(connection)`
  ที่แยกกันด้วย accessible name (`Edit environment <project/env>` / `Edit connection <project/env>`) · แถว env `registry` ไม่มีทั้งสองลิงก์ ·
  หน้า `connections/show` ของ connection local มีลิงก์ไปแก้ env ของมัน
- [ ] **Step 2:** FAIL → ทำ UI: Remove ยังเป็น action ทำลายอันเดียวที่อยู่อีกฝั่งของเส้นคั่น · 390px ปุ่มไม่ล้นแถว
- [ ] **Step 3:** PASS · snapshot `connections-index-projects` อัปเดต · detect ไม่เพิ่ม
- [ ] **Step 4:** Commit `feat(R1.15): a connected env can be edited from its row`

---

### Task R1.16: ข้อความ `ConflictingRepos` ทำตามได้จริงตอน migrate (backend)

**ชั้น:** backend · **ต้องเสร็จก่อน:** R1.2 · **ไฟล์ที่แก้ได้:** `app/services/kong/legacy_project_backfill.rb`, `spec/services/kong/legacy_project_backfill_spec.rb`, `docs/plans/00-roadmap.md` (ตาราง Migrations แถว #3 คอลัมน์ Rollback)

**ทำไม:** ข้อค้าง 3 — ข้อความเดิมบอกให้แก้ `config/connections.yml` "before migrating" แต่ตอนนั้น `kong:load_connections` ใช้ไม่ได้
(`column kong_connections.project_env_id does not exist`) · ไม่เปลี่ยนพฤติกรรม: ยังปฏิเสธเหมือนเดิม

- [ ] **Step 1: test**

```ruby
# spec/services/kong/legacy_project_backfill_spec.rb — แก้ it เดิมที่ตรวจ ConflictingRepos + เพิ่ม
# `legacy(attrs)` = helper เดิมของไฟล์นี้ (save!(validate: false))
let(:pr_attrs) { { admin_url: "http://localhost:8001", apply_mode: "pr" } }

it "names each PR connection with its repo and says how to continue from this schema" do
  legacy(pr_attrs.merge(name: "uat", env: "uat", rank: 2, color_tag: "orange", git_repo: "/tmp/a.git"))
  legacy(pr_attrs.merge(name: "prod", env: "prod", rank: 3, color_tag: "red", git_repo: "/tmp/b.git"))
  expect { described_class.call }.to raise_error(described_class::ConflictingRepos) { |e|
    expect(e.message).to include("uat → /tmp/a.git", "prod → /tmp/b.git")
    expect(e.message).to include("Nothing was changed", "bin/rails console", "update_all(git_repo:", "bin/rails db:migrate")
    expect(e.message).not_to include("kong:load_connections")
  }
end

it "goes through once the connections are pointed at one repo, as the message says" do
  legacy(pr_attrs.merge(name: "uat", env: "uat", rank: 2, color_tag: "orange", git_repo: "/tmp/a.git"))
  legacy(pr_attrs.merge(name: "prod", env: "prod", rank: 3, color_tag: "red", git_repo: "/tmp/b.git"))
  KongConnection.where(apply_mode: "pr").update_all(git_repo: "/tmp/a.git")
  expect { described_class.call }.not_to raise_error
  expect(Project.find_by!(key: "default").git_repo).to eq("/tmp/a.git")
end
```

- [ ] **Step 2:** FAIL → implement ข้อความ (ภาษาอังกฤษ หลายบรรทัด): รายการ `name → repo` ต่อบรรทัด · "Nothing was changed: this migration was rolled back." ·
  ทางที่ทำได้ ณ schema นั้น: ใน `bin/rails console` ใช้ `KongConnection.where(name: [...]).update_all(git_repo: "<repo ที่ถูก>")` หรือลบ connection ที่ไม่ใช้แล้ว → `bin/rails db:migrate` อีกครั้ง ·
  บอกว่าหลัง migrate ทุก connection อยู่ใน project `default` เป็น `default/<ชื่อเดิม>`
- [ ] **Step 3:** เพิ่มขั้นตอนเดียวกันในคอลัมน์ Rollback แถว #3 ของ `00-roadmap.md`
- [ ] **Step 4:** PASS · suite 0 failures · Commit `fix(R1.16): the conflicting-repos refusal says how to continue from where the migration stopped`

---

### Task R1.17: ตรวจซ้ำหลัง R1.13–R1.16 (verification)

**ชั้น:** — · **ต้องเสร็จก่อน:** R1.13–R1.16

- [ ] compose: env `apply_mode` ว่าง → หน้า entities / entity / plan review ไม่มีปุ่มเขียน มี notice; เปิด `/entities/new?type=upstream` ตรง → กลับไป list พร้อมเหตุผล;
  ตั้งกลับเป็น Direct apply ผ่านลิงก์ใหม่ในแถว env → ปุ่มกลับมา · connection `access_level: ro` (`local/dev-ro`) direct → ไม่มีปุ่มเขียน · `local/uat` (PR, ro) → ยังมีปุ่ม
- [ ] สำเนา DB dev: rollback STEP=4 → migrate ที่ PR คนละ repo → ข้อความใหม่ → ทำตามข้อความ → migrate สำเร็จ · drop สำเนา
- [ ] `bundle exec rspec` 0 failures · vitest ผ่าน · detect ไม่เพิ่ม · ภาพหน้าจอ 390/1280 ของหน้าที่เปลี่ยน · ลบข้อมูลทดสอบใน DB dev

## เกณฑ์ปิดงาน R1

- [ ] เกณฑ์ใน `R1-multi-project-env.md` (ฉบับแก้ §C2) ครบทุกข้อ พร้อมหลักฐาน
- [ ] migration 4 ตัว up/down ผ่านบน DB สำเนา
- [ ] `bundle exec rspec` 0 failures · `cd mcp && npm test` ผ่าน · detect ไม่เพิ่ม
- [ ] `hints:todo` ของ key ใหม่รายงานแล้ว
- [ ] ไม่มี credential หลุด: `log_filtering_spec` ผ่าน; API connections ไม่มี `auth_secret`
