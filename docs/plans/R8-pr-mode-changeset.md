# R8 — PR mode changeset Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** ทุกการเขียนบน connection PR mode สะสมเป็น changeset (ไม่หมดอายุ, ดู/แก้/ลบรายการได้) → preview YAML diff ทั้งชุด → ตรวจ drift + CiGate ใน Kongsole → push branch ครั้งเดียวพร้อม PR body ที่มี `Changed-by:` → แสดงลิงก์ branch และเก็บ URL ของ PR ที่ผู้ใช้วาง

**Architecture:** ขยาย ChangePlan เดิม (DESIGN §6 "R8 ขยายแนวคิด ChangePlan") — `changesets` เป็นกลุ่มของ plan; `Kong::ChangesetRenderer` ใช้ `DeckDocument` + `DeckRenderer` เดิมกับทุก plan ตามลำดับบนไฟล์จาก git ล่าสุด; `Kong::ChangesetSubmitter` เป็นเส้นทางเดียวที่ push; `Kong::ChangeApplier` ปฏิเสธ plan PR mode (ต้องไปทาง changeset) · ไม่มี git host API (Q9)

**Tech Stack:** Rails 8.1, `git` CLI (`Kong::GitClient`), decK CLI 1.51.1/1.66.1 (`Kong::DeckCli`), RSpec

**Spec:** `docs/requirements/R8-pr-mode-changeset.md` (+ `design-amendments.md` §C9, §A2), `docs/DESIGN.md` §6, §10, `docs/plans/00-roadmap.md` (Q9–Q14)

## Global Constraints

- connection `apply_mode = pr` ห้ามเรียก Admin API แบบเขียนทุกกรณี — ใช้ credential ro เพื่อ `deck gateway diff` เท่านั้น
- YAML render จาก git ล่าสุดเสมอ, `_info.select_tags` บังคับ (`require_select_tags!` เดิม), round-trip byte-exact (`DeckDocument.verify_input!` ทั้ง input และ output)
- entity ที่เป็น admin path ห้ามอยู่ใน changeset (ปฏิเสธตอนเพิ่ม **และ** ตอน submit); credential ของ consumer ไม่ render
- 1 changeset เปิดได้ครั้งละ 1 ต่อ connection (Q10); direct mode ไม่มี changeset (Q12)
- agent (MCP) เพิ่มรายการได้ แต่ **submit ได้เฉพาะคน** ผ่านเว็บ (Q13)
- threshold การลบ = `project.delete_threshold` (default 3, Q11 ค้าง)
- rank ≥ 2: submit ต้องพิมพ์ชื่อ connection + ใส่รหัสผ่านซ้ำ (เหมือน apply เดิม)
- branch: `kongctl/changeset-<id>` · commit trailer `Changed-by: <operator>` เมื่อมี operator

## Review Focus

1. changeset ที่มี create service `billing` + create route ใต้ `billing` (service ยังไม่มีใน Kong) → route ต้อง nest ใต้ service ใน YAML เดียวกัน — test ใน R8.3
2. plan update 2 ตัวบน entity เดียวกันใน changeset เดียว → ตัวหลังต้องเห็นผลของตัวแรก (ไม่ใช่ทับด้วย `before` เก่า) หรือถูกปฏิเสธตอนเพิ่ม — test ใน R8.2 (ปฏิเสธ: "already in this changeset — edit that item instead")
3. git มี commit ใหม่หลังเริ่ม changeset แต่ไม่ขัดกัน → submit ได้หลังผู้ใช้ยืนยัน drift และ render บน git ล่าสุด — test ใน R8.5
4. submit ล้มกลางทาง (decK validate ไม่ผ่าน) → ไม่มีอะไรถูก push, changeset ยัง `open`, plan ยัง `pending`, working copy สะอาด — test ใน R8.6
5. plan ใน changeset ถูกเปิดด้วย `kong_apply` หรือ `POST /change_plans/:id/apply` → ปฏิเสธโดยไม่แตะ git — test ใน R8.7

---

## Spec ที่ตกลงแล้ว

- **Changeset** ของ connection หนึ่ง: `status` ∈ `open | submitted | abandoned`; `base_git_sha` (HEAD ของ `git_branch` ตอนเปิด), ผู้เปิด (`actor_username`, `actor_operator`), หลัง submit: `branch`, `commit_sha`, `deck_diff`, `gate_reasons`, `pr_body`, `pr_url`, `submitted_at`, `submitted_by`
- plan ใน changeset: `status = pending` จนกว่า submit (→ `applied`, `pr_state = "branch_pushed"`) หรือถูกลบออก (→ `cancelled`); `expired?` = false เมื่ออยู่ใน changeset
- create ใน PR mode ได้ `provisional_kong_id` (uuid) ให้ลูกใน changeset เดียวกันอ้างเป็น `parent_kong_id` ได้
- "แก้รายการ" = เปิดฟอร์มเดิมด้วยค่าของ plan แล้วสร้าง plan ใหม่ที่ `replaces_plan_id` → plan เก่า `cancelled` (ลำดับของรายการใหม่ = ลำดับเดิม)
- preview = render จริงบน working copy + `git diff` (ไม่ commit ไม่ push) + `deck gateway diff` (ro) + CiGate → แสดงผลทั้งหมด
- drift: (ก) git: `ls-remote` HEAD ≠ `base_git_sha` → นับ commit และแสดง; (ข) Kong: plan update/delete ที่ live `updated_at` ≠ `base_updated_at` → รายการ; ถ้ามี drift submit ต้องมี `acknowledge_drift=1`
- CiGate ใน Kongsole ก่อน push: admin path (ชื่อจาก read-model `is_admin_path`) + delete เกิน threshold → **block** (ไม่มี override ใน UI)
- PR body (markdown): หัวเรื่อง, ตารางรายการ (operation/type/name), สรุป deck diff (creating/updating/deleting), ผล CiGate, `Changeset: <id>`, `Plans: <ids>`, trailer `Changed-by:`
- หลัง push: ลิงก์ branch จาก `connection.branch_url(branch)` (มีอยู่แล้ว), ปุ่มคัดลอก PR body, ช่องวาง PR URL (ต้องเป็น http(s) และ host ตรงกับ `git_web_url` ถ้ามี)
- `bin/deck-ci-gate --changeset <id>` สำหรับ CI (คงรูปแบบ `<change_plan_id>` เดิมไว้)

## Contract UI ↔ backend

| backend ให้ | รายละเอียด |
|---|---|
| routes | `resources :changesets, only: %i[index show] do member { get :preview; post :submit; patch :pr_url; post :abandon } end` · `delete "/changesets/:changeset_id/items/:id" => "changeset_items#destroy", as: :changeset_item` |
| `@changeset` | `Changeset` + `#items` (plans `pending` เรียงตาม `position`), `#connection`, `#open?`, `#branch_url` |
| `@preview` (`changesets#preview`) | `Kong::ChangesetRenderer::Preview(yaml_diff: String, deck_diff: Hash \| nil, gate: Kong::CiGate::Result, drift: Kong::ChangesetDrift::Report, error: String \| nil)` |
| `Kong::ChangesetDrift::Report` | `git_moved?`, `commits_behind` (Integer \| nil), `kong_changed` (Array of `{plan_id:, label:}`), `any?` |
| submit params | `confirm_env_name` (rank ≥ 2), `password` (rank ≥ 2), `acknowledge_drift` ("1"), `acknowledge_env_vars` ("1" ถ้ามี certificate) |
| submit result | redirect `changeset_path` + flash; `@changeset.pr_body`, `@changeset.branch`, `@changeset.branch_url` |
| error | `flash[:alert]` + `flash[:error_explanation]` (R3) · failure ของ git/decK เก็บที่ `changeset.failure_reason` |
| `current_open_changeset` (helper_method) | changeset `open` ของ connection ปัจจุบัน หรือ nil — สำหรับ badge ใน nav |
| plan review page (`change_plans#show`) | `@change_plan.changeset` → แสดง "In changeset #N" แทน action bar |

---

### Task R8.1: `changesets` + ความสัมพันธ์กับ plan (backend)

**ชั้น:** backend · **ต้องเสร็จก่อน:** R1 ทั้งหมด · **ไฟล์ที่แก้ได้:**
- Create: `db/migrate/<ts>_create_changesets.rb`, `db/migrate/<ts>_add_changeset_to_change_plans.rb`, `app/models/changeset.rb`, `spec/models/changeset_spec.rb`, `spec/factories/changesets.rb`
- Modify: `app/models/change_plan.rb`, `spec/models/change_plan_spec.rb`, `spec/factories/change_plans.rb`

**Interfaces:**
- `Changeset.open_for!(connection:, actor_username:, actor_operator:) -> Changeset` (หาอันที่เปิดอยู่หรือสร้าง; `base_git_sha` ใส่ภายหลังโดย R8.5)
- `Changeset#items`, `#open?`, `#branch_url`
- `ChangePlan belongs_to :changeset, optional: true`; `ChangePlan#in_changeset?`; `#expired?` → false ถ้า `in_changeset?`; `position` (integer)

- [x] **Step 1: test**

```ruby
# spec/models/changeset_spec.rb
require "rails_helper"

RSpec.describe Changeset do
  let(:connection) { create(:kong_connection, project_env: create(:project_env, name: "uat", apply_mode: "pr", source: "registry")) }

  it "keeps a single open changeset per connection" do
    first = described_class.open_for!(connection: connection, actor_username: "a", actor_operator: nil)
    expect(described_class.open_for!(connection: connection, actor_username: "b", actor_operator: nil)).to eq(first)
    expect { described_class.create!(kong_connection: connection, status: "open", actor_username: "c") }
      .to raise_error(ActiveRecord::RecordNotUnique)
  end

  it "refuses a direct-mode connection" do
    direct = create(:kong_connection)
    expect { described_class.open_for!(connection: direct, actor_username: "a", actor_operator: nil) }
      .to raise_error(Kong::ChangeGuardrails::Violation, /PR mode/)
  end
end
```

```ruby
# spec/models/change_plan_spec.rb — เพิ่ม
it "does not expire while it sits in a changeset" do
  plan = create(:change_plan, expires_at: 1.day.ago, changeset: create(:changeset))
  expect(plan.expired?).to be(false)
end
```

- [x] **Step 2:** FAIL → migrations:

```ruby
class CreateChangesets < ActiveRecord::Migration[8.1]
  def change
    create_table :changesets do |t|
      t.references :kong_connection, null: false, foreign_key: true
      t.string :status, null: false, default: "open"
      t.string :actor_username, null: false
      t.string :actor_operator
      t.string :base_git_sha
      t.string :branch
      t.string :commit_sha
      t.jsonb :deck_diff
      t.jsonb :gate_reasons, null: false, default: []
      t.text :pr_body
      t.string :pr_url
      t.text :failure_reason
      t.string :submitted_by
      t.datetime :submitted_at
      t.timestamps
    end
    add_index :changesets, :kong_connection_id, unique: true, where: "status = 'open'", name: "index_changesets_one_open_per_connection"
  end
end

class AddChangesetToChangePlans < ActiveRecord::Migration[8.1]
  def change
    add_reference :change_plans, :changeset, foreign_key: true
    add_column :change_plans, :position, :integer
    add_column :change_plans, :provisional_kong_id, :uuid
    add_reference :change_plans, :replaces_plan, foreign_key: { to_table: :change_plans }
  end
end
```

- [x] **Step 3:** models → PASS · migrate/rollback/migrate · suite 0 failures
- [x] **Step 4:** Commit `feat(R8.1): changesets group PR-mode plans; plans in one never expire`

---

### Task R8.2: planner ส่ง plan PR mode เข้า changeset (backend)

**ชั้น:** backend · **ต้องเสร็จก่อน:** R8.1 · **ไฟล์ที่แก้ได้:** `app/services/kong/change_planner.rb`, `app/controllers/api/v1/change_plans_controller.rb` (response มี `changeset_id`), `spec/services/kong/change_planner_spec.rb`, `spec/requests/api/v1/change_plans_spec.rb`

**Interfaces:** `Kong::ChangePlanner.new(…, replaces_plan_id: nil)`; PR mode → plan มี `changeset`, `position`, (create) `provisional_kong_id`; ปฏิเสธ (`InvalidChange`): (ก) entity admin path ("admin-path entities never go into a changeset"), (ข) มี plan pending อีกตัวบน `target_kong_id` เดียวกันใน changeset และไม่ได้ `replaces_plan_id` มัน

- [x] **Step 1: test**

```ruby
describe "PR mode" do
  let(:env) { create(:project_env, name: "uat", apply_mode: "pr", source: "registry", select_tags: %w[managed-by-kongctl]) }
  let(:connection) { create(:kong_connection, project_env: env, access_level: "ro", admin_url: "https://kong.test") }
  let(:client) { Kong::Client.new(connection: connection, secret: "pw") }

  def plan_create(name)
    described_class.new(connection: connection, client: client, operation: "create", entity_type: "service",
      actor_username: "alice", attributes: { "name" => name, "url" => "http://#{name}.internal" }).call
  end

  it "puts every plan into the connection's open changeset, in order, and makes no write call" do
    a = plan_create("billing")
    b = plan_create("ledger")
    expect(a.changeset).to eq(b.changeset)
    expect([ a.position, b.position ]).to eq([ 1, 2 ])
    expect(a.provisional_kong_id).to be_present
    expect(a_request(:any, /kong\.test/).with { |req| req.method != :get }).not_to have_been_made
  end

  it "refuses a second item on the same entity unless it replaces the first" do
    live = { "id" => SecureRandom.uuid, "name" => "billing", "tags" => [], "updated_at" => 1 }
    stub_request(:get, "https://kong.test/services/#{live['id']}").to_return(status: 200, body: live.to_json)
    first = described_class.new(connection: connection, client: client, operation: "update", entity_type: "service",
      target_kong_id: live["id"], actor_username: "a", attributes: { "tags" => %w[x] }).call
    expect {
      described_class.new(connection: connection, client: client, operation: "update", entity_type: "service",
        target_kong_id: live["id"], actor_username: "a", attributes: { "tags" => %w[y] }).call
    }.to raise_error(Kong::ChangePlanner::InvalidChange, /already in this changeset/)

    replacement = described_class.new(connection: connection, client: client, operation: "update", entity_type: "service",
      target_kong_id: live["id"], actor_username: "a", attributes: { "tags" => %w[y] }, replaces_plan_id: first.id).call
    expect(first.reload.status).to eq("cancelled")
    expect(replacement.position).to eq(first.position)
  end

  it "refuses an admin-path entity before it reaches the changeset" do
    admin_id = SecureRandom.uuid
    connection.update!(admin_path_fingerprint: { "service_id" => admin_id, "route_ids" => [], "plugin_ids" => [], "consumer_ids" => [] })
    stub_request(:get, "https://kong.test/services/#{admin_id}")
      .to_return(status: 200, body: { id: admin_id, name: "admin-api", tags: %w[kong-admin-path], updated_at: 1 }.to_json)

    expect {
      described_class.new(connection: connection, client: client, operation: "update", entity_type: "service",
        target_kong_id: admin_id, actor_username: "a", attributes: { "tags" => %w[x] }).call
    }.to raise_error(Kong::ChangePlanner::InvalidChange, /admin-path/)
    expect(Changeset.count).to eq(0)
  end
end
```

- [x] **Step 2:** FAIL → implement → PASS
- [x] **Step 3:** API test: `kong_plan` บน PR connection คืน `changeset_id` และ `status: "pending"`
- [x] **Step 4:** suite 0 failures · Commit `feat(R8.2): PR-mode proposals collect in the connection's open changeset`

---

### Task R8.3: resolver ที่รู้จักรายการใน changeset (backend)

**ชั้น:** backend · **ต้องเสร็จก่อน:** R8.2 · **ไฟล์ที่แก้ได้:** Create `app/services/kong/changeset_resolver.rb`, `spec/services/kong/changeset_resolver_spec.rb`; Modify `spec/services/kong/deck_renderer_spec.rb` (เพิ่ม example)

**Interfaces:** `Kong::ChangesetResolver.new(changeset)` — duck type เดียวกับ `DeckReadModelResolver` (`name_of(kong_id)`, `parent_of(kong_id)`) ลอง read-model ก่อน แล้วหา plan create ใน changeset ที่ `provisional_kong_id == kong_id` (ชื่อจาก `after[definition.deck_key]`, parent จาก `parent_kong_id`)

- [x] **Step 1: test**

```ruby
require "rails_helper"

RSpec.describe Kong::ChangesetResolver do
  it "names a service that exists only as a create in the same changeset" do
    changeset = create(:changeset)
    service = create(:change_plan, changeset: changeset, operation: "create", entity_type: "service",
      provisional_kong_id: SecureRandom.uuid, after: { "name" => "billing" }, kong_connection: changeset.kong_connection)
    resolver = described_class.new(changeset)
    expect(resolver.name_of(service.provisional_kong_id)).to eq("billing")
  end

  it "prefers the read-model for entities that already exist" do
    changeset = create(:changeset)
    entity = create(:kong_entity, kong_connection: changeset.kong_connection, entity_type: "service", name: "ledger")
    expect(described_class.new(changeset).name_of(entity.kong_id)).to eq("ledger")
  end
end
```

```ruby
# spec/services/kong/deck_renderer_spec.rb — เพิ่ม
it "nests a route under a service created earlier in the same changeset" do
  changeset = create(:changeset)
  connection = changeset.kong_connection
  provisional = SecureRandom.uuid
  service_plan = create(:change_plan, changeset: changeset, kong_connection: connection, position: 1, apply_mode: "pr",
    operation: "create", entity_type: "service", provisional_kong_id: provisional,
    after: { "name" => "billing", "host" => "billing.internal", "tags" => %w[managed-by-kongctl] })
  route_plan = create(:change_plan, changeset: changeset, kong_connection: connection, position: 2, apply_mode: "pr",
    operation: "create", entity_type: "route", parent_kong_id: provisional,
    after: { "name" => "billing-v1", "paths" => %w[/billing], "service" => { "id" => provisional }, "tags" => %w[managed-by-kongctl] })
  doc = Kong::DeckDocument.parse(nil, select_tags: %w[managed-by-kongctl])
  resolver = Kong::ChangesetResolver.new(changeset)

  [ service_plan, route_plan ].each { |plan| described_class.apply_change(doc, plan, resolver: resolver) }
  parsed = YAML.safe_load(Kong::DeckDocument.serialize(doc))

  expect(parsed["services"].map { _1["name"] }).to eq(%w[billing])
  expect(parsed["services"].first["routes"].map { _1["name"] }).to eq(%w[billing-v1])
  expect(parsed["services"].first["routes"].first).not_to have_key("service")
end
```

- [x] **Step 2:** FAIL → implement → PASS · Commit `feat(R8.3): children can nest under parents created in the same changeset`

---

### Task R8.4: render changeset + preview diff (backend)

**ชั้น:** backend · **ต้องเสร็จก่อน:** R8.3 · **ไฟล์ที่แก้ได้:**
- Create: `app/services/kong/changeset_renderer.rb`, `spec/services/kong/changeset_renderer_spec.rb`, `spec/support/bare_git_repo.rb` (`module BareGitRepo`: `bare_git_repo(path:, select_tags:) -> Pathname` สร้าง bare repo ชั่วคราวที่มีไฟล์ `Kong::DeckDocument.serialize(parse(nil, select_tags:))` แบบเดียวกับ `rake kong:seed_config_repo`; `head_sha(repo) -> String`; `push_empty_commit(repo)`; `pr_connection_for(repo, path:, select_tags:) -> KongConnection` สร้าง project/env PR mode ที่ชี้ repo นี้)
- Modify: `app/services/kong/git_client.rb` (`#diff(path) -> String`, `#remote_head_sha -> String`, `#discard!`; error แยก `Kong::GitClient::Unreachable` (`kind` จาก `Kong::NetworkFailure.classify_text`) และ `Kong::GitClient::AuthFailed` — ทั้งคู่ < `GitClient::Error` เดิม), `app/services/kong/error_explanation.rb` (mapping `GitClient::Unreachable` → `network_*`, `GitClient::AuthFailed` → `git_auth_failed`), `spec/services/kong/error_explanation_spec.rb`, `config/locales/hints.en.yml` (`hints.errors.git_auth_failed.*` ค่า `To Edit: pending`), `app/services/kong/deck_cli.rb` (`validate(file_path, extra_paths: [])`, `diff(file_path, connection:, secret:, extra_paths: [])`), `spec/services/kong/git_client_spec.rb`, `spec/services/kong/deck_cli_spec.rb`

**Interfaces:**
- `Kong::ChangesetRenderer.new(changeset:, secret:).preview -> Preview` (ไม่ commit ไม่ push; `discard!` working copy เสมอใน `ensure`)
- `Kong::ChangesetRenderer#render!(git) -> String` (ใช้ร่วมกับ R8.6): `DeckRenderer.assert_supported!` ทุก plan → `require_select_tags!` → `verify_input!` → `parse` → `apply_change` ทีละ plan ตาม `position` ด้วย `ChangesetResolver` → `serialize` → `verify_input!(rendered)`
- `Preview = Struct.new(:yaml_diff, :deck_diff, :gate, :drift, :error, :explanation, keyword_init: true)` — `explanation` = `Kong::ErrorExplanation::Result` (พร้อม `network_note` ของ project) เมื่อ git/decK/Kong เข้าไม่ถึง; หน้า changeset ยังแสดงรายการได้ปกติ
- `deck_extra_paths` ของ env ถูกส่งต่อเป็น positional file เพิ่มให้ `deck file validate` / `deck gateway diff` (อ่านอย่างเดียว ไม่แก้)

- [x] **Step 1: test**

```ruby
require "rails_helper"

RSpec.describe Kong::ChangesetRenderer do
  include BareGitRepo

  let(:repo) { bare_git_repo(path: "uat/kong.yaml", select_tags: %w[managed-by-kongctl]) }
  let(:project) { create(:project, git_repo: repo.to_s, git_branch: "main") }
  let(:env) { create(:project_env, project: project, name: "uat", apply_mode: "pr", source: "registry",
    git_path: "uat/kong.yaml", select_tags: %w[managed-by-kongctl]) }
  let(:connection) { create(:kong_connection, project_env: env) }
  let(:changeset) { create(:changeset, kong_connection: connection) }

  before do
    allow(Kong::DeckCli).to receive(:validate).and_return(true)
    allow(Kong::DeckCli).to receive(:diff).and_return({ "changes" => { "creating" => [ { "kind" => "service", "name" => "billing" } ], "updating" => [], "deleting" => [] } })
  end

  it "previews the whole changeset as one YAML diff without committing or pushing" do
    create(:change_plan, changeset: changeset, kong_connection: connection, position: 1, operation: "create",
      entity_type: "service", apply_mode: "pr", provisional_kong_id: SecureRandom.uuid,
      after: { "name" => "billing", "host" => "billing.internal", "tags" => %w[managed-by-kongctl] })

    preview = described_class.new(changeset: changeset, secret: "pw").preview

    expect(preview.yaml_diff).to include("+  - name: billing")
    expect(preview.gate).to be_passed
    expect(`git --git-dir=#{repo} branch --list 'kongctl/*'`).to be_empty
  end

  it "reports an unrenderable item as the preview error, leaving the working copy clean" do
    create(:change_plan, changeset: changeset, kong_connection: connection, position: 1, operation: "update",
      entity_type: "service", apply_mode: "pr", before: { "name" => "ghost" }, after: { "name" => "ghost", "tags" => [] })
    preview = described_class.new(changeset: changeset, secret: "pw").preview
    expect(preview.error).to match(/no service ghost in this YAML/)
  end

  it "explains a config repo this machine cannot reach, with the project's network note" do
    project.update!(network_note: "Reachable from the NONPROD VPN only")
    allow_any_instance_of(Kong::GitClient).to receive(:pull!)
      .and_raise(Kong::GitClient::Unreachable.new("git fetch failed", kind: :dns))
    preview = described_class.new(changeset: changeset, secret: "pw").preview
    expect(preview.explanation.key).to eq("network_dns_failed")
    expect(preview.explanation.next_step).to include("NONPROD VPN")
  end
end
```

```ruby
# spec/services/kong/git_client_spec.rb — เพิ่ม
it "tells an unreachable git host apart from a refused key" do
  connection = create(:kong_connection, project_env: create(:project_env, apply_mode: "pr", source: "registry",
    project: create(:project, git_repo: "https://git.example/team/repo.git")))
  failed = instance_double(Process::Status, success?: false)
  allow(Open3).to receive(:capture3)
    .and_return([ "", "fatal: unable to access 'https://git.example/team/repo.git/': Could not resolve host: git.example", failed ])
  expect { described_class.new(connection: connection, working_dir: Pathname(Dir.mktmpdir)).pull! }
    .to raise_error(described_class::Unreachable) { |e| expect(e.kind).to eq(:dns) }

  allow(Open3).to receive(:capture3).and_return([ "", "git@git.example: Permission denied (publickey).", failed ])
  expect { described_class.new(connection: connection, working_dir: Pathname(Dir.mktmpdir)).pull! }
    .to raise_error(described_class::AuthFailed)
end
```

- [x] **Step 2:** FAIL → implement (GitClient เพิ่ม method + test ของตัวเอง; DeckCli เพิ่ม `extra_paths` + test ว่า argv มีไฟล์เพิ่ม และ error message ไม่มี header `Authorization`)
- [x] **Step 3:** PASS · suite 0 failures · Commit `feat(R8.4): render a whole changeset from the latest git and preview its diff`

---

### Task R8.5: drift ของ git และ Kong (backend)

**ชั้น:** backend · **ต้องเสร็จก่อน:** R8.4 · **ไฟล์ที่แก้ได้:** Create `app/services/kong/changeset_drift.rb`, `spec/services/kong/changeset_drift_spec.rb`; Modify `app/models/changeset.rb` (`base_git_sha` ตั้งตอน `open_for!` ด้วย `GitClient#remote_head_sha`, error → nil), `spec/models/changeset_spec.rb`

**Interfaces:** `Kong::ChangesetDrift.check(changeset:, git:, client:) -> Report`; `Report = Struct.new(:commits_behind, :kong_changed, keyword_init: true)` + `git_moved?` (`commits_behind.to_i > 0` หรือ base nil → `nil` = unknown แสดงเป็นเตือน), `any?`

- [x] **Step 1: test**

```ruby
require "rails_helper"

RSpec.describe Kong::ChangesetDrift do
  include BareGitRepo

  it "counts commits pushed to the base branch since the changeset started" do
    repo = bare_git_repo(path: "uat/kong.yaml", select_tags: %w[t])
    connection = pr_connection_for(repo, path: "uat/kong.yaml", select_tags: %w[t])
    changeset = create(:changeset, kong_connection: connection, base_git_sha: head_sha(repo))
    push_empty_commit(repo)
    git = Kong::GitClient.new(connection: connection).pull!
    report = described_class.check(changeset: changeset, git: git, client: nil)
    expect(report.commits_behind).to eq(1)
    expect(report).to be_any
  end

  it "lists update/delete items whose entity changed in Kong since they were proposed" do
    repo = bare_git_repo(path: "uat/kong.yaml", select_tags: %w[t])
    connection = pr_connection_for(repo, path: "uat/kong.yaml", select_tags: %w[t])
    connection.update!(admin_url: "https://kong.test")
    changeset = create(:changeset, kong_connection: connection, base_git_sha: head_sha(repo))
    kong_id = SecureRandom.uuid
    plan = create(:change_plan, changeset: changeset, kong_connection: connection, position: 1, apply_mode: "pr",
      operation: "update", entity_type: "service", target_kong_id: kong_id, base_updated_at: Time.zone.at(100),
      before: { "id" => kong_id, "name" => "billing" }, after: { "name" => "billing", "tags" => %w[t] })
    stub_request(:get, "https://kong.test/services/#{kong_id}")
      .to_return(status: 200, body: { id: kong_id, name: "billing", updated_at: 200 }.to_json)
    client = Kong::Client.new(connection: connection, secret: "pw")
    git = Kong::GitClient.new(connection: connection).pull!

    report = described_class.check(changeset: changeset, git: git, client: client)

    expect(report.kong_changed).to eq([ { plan_id: plan.id, label: "service billing" } ])
    expect(a_request(:any, /kong\.test/).with { |req| req.method != :get }).not_to have_been_made
  end
end
```

- [x] **Step 2:** FAIL → implement → PASS · Commit `feat(R8.5): tell whether git or Kong moved since a changeset began`

---

### Task R8.6: submit changeset (backend)

**ชั้น:** backend · **ต้องเสร็จก่อน:** R8.5 · **ไฟล์ที่แก้ได้:** Create `app/services/kong/changeset_submitter.rb`, `app/services/kong/pr_body.rb`, `spec/services/kong/changeset_submitter_spec.rb`, `spec/services/kong/pr_body_spec.rb`; Modify `bin/deck-ci-gate` (`--changeset <id>`), `spec/bin/deck_ci_gate_spec.rb` (create ถ้าไม่มี)

**Interfaces:**
- `Kong::ChangesetSubmitter.new(changeset:, client:, secret:, actor_username:, actor_operator:, acknowledge_drift: false, env_acknowledged: false).call -> Changeset`
- ลำดับ: `open?` · มี item ≥ 1 · `check_write_access!` · admin path ต่อ item · `CertificateKeyPolicy.check!` + env ack ต่อ item · drift (`acknowledge_drift` ถ้า `any?`) · `render!` · `DeckCli.validate` · `DeckCli.diff` · `CiGate.check(deck_diff:, admin_path_names:, delete_threshold: project.delete_threshold)` → block ถ้าไม่ผ่าน · checkout `kongctl/changeset-<id>` · write · commit (`PrBody.commit_message`) · push · update changeset/plans/audit ใน transaction เดียว
- ล้มก่อน push → `git.discard!`, changeset คง `open`, `failure_reason` (scrubbed เหมือน `ChangeApplier#failure_reason_for`)
- `Kong::PrBody.markdown(changeset, deck_diff:, gate:) -> String`, `Kong::PrBody.commit_message(changeset) -> String`

- [x] **Step 1: test**

```ruby
require "rails_helper"

RSpec.describe Kong::ChangesetSubmitter do
  include BareGitRepo
  # let(:repo/project/env/connection/changeset) เหมือน changeset_renderer_spec

  before do
    allow(Kong::DeckCli).to receive(:validate).and_return(true)
    allow(Kong::DeckCli).to receive(:diff).and_return({ "changes" => { "creating" => [ { "kind" => "service", "name" => "billing" } ], "updating" => [], "deleting" => [] } })
  end

  it "pushes one branch with every item, a Changed-by trailer, and records the result" do
    add_create_item(changeset, "billing")
    add_create_item(changeset, "ledger")

    result = described_class.new(changeset: changeset, client: nil, secret: "pw", actor_username: "kong-admin", actor_operator: "somchai@example.com").call

    expect(result).to have_attributes(status: "submitted", branch: "kongctl/changeset-#{changeset.id}")
    log = `git --git-dir=#{repo} log -1 --format=%B kongctl/changeset-#{changeset.id}`
    expect(log).to include("Changed-by: somchai@example.com")
    expect(changeset.items.reload.map(&:status)).to all(eq("applied"))
    expect(AuditEvent.where(change_plan_id: changeset.change_plans.ids).count).to eq(2)
    expect(result.pr_body).to include("billing", "ledger", "Changed-by: somchai@example.com")
  end

  it "blocks before pushing when the diff deletes more than the project's threshold" do
    changeset.kong_connection.project_env.project.update!(delete_threshold: 1)
    allow(Kong::DeckCli).to receive(:diff).and_return({ "changes" => { "creating" => [], "updating" => [],
      "deleting" => [ { "kind" => "service", "name" => "a" }, { "kind" => "service", "name" => "b" } ] } })
    add_create_item(changeset, "billing")

    expect { described_class.new(changeset: changeset, client: nil, secret: "pw", actor_username: "a", actor_operator: nil).call }
      .to raise_error(Kong::ChangeGuardrails::Violation, /over the threshold of 1/)
    expect(`git --git-dir=#{repo} branch --list 'kongctl/*'`).to be_empty
    expect(changeset.reload).to be_open
  end

  it "leaves everything as it was when decK rejects the file" do
    allow(Kong::DeckCli).to receive(:validate).and_raise(Kong::DeckCli::Error, "deck file validate failed: bad")
    add_create_item(changeset, "billing")
    expect { described_class.new(changeset: changeset, client: nil, secret: "pw", actor_username: "a", actor_operator: nil).call }
      .to raise_error(Kong::DeckCli::Error)
    expect(changeset.reload).to have_attributes(status: "open", failure_reason: include("deck file validate failed"))
    expect(changeset.items.map(&:status)).to all(eq("pending"))
  end

  it "requires acknowledging drift before submitting over it" do
    changeset.update!(base_git_sha: "0" * 40)
    add_create_item(changeset, "billing")
    expect { described_class.new(changeset: changeset, client: nil, secret: "pw", actor_username: "a", actor_operator: nil).call }
      .to raise_error(Kong::ChangeGuardrails::Violation, /changed since this changeset began/)
  end

  it "makes no write call to Kong" do
    add_create_item(changeset, "billing")
    described_class.new(changeset: changeset, client: nil, secret: "pw", actor_username: "a", actor_operator: nil).call
    expect(a_request(:any, //).with { |req| %i[post put patch delete].include?(req.method) }).not_to have_been_made
  end
end
```
(`add_create_item` เป็น helper ใน spec ที่สร้าง `change_plan` create service ใน changeset)

- [x] **Step 2:** FAIL → implement → PASS
- [x] **Step 3:** `bin/deck-ci-gate --changeset <id>` test: ผ่าน/ไม่ผ่านตาม `changeset.deck_diff` + `delete_threshold`
- [x] **Step 4:** suite 0 failures · Commit `feat(R8.6): submit a changeset as one gated branch with a PR body`

---

### Task R8.7: ปิดเส้นทาง PR แบบ plan เดี่ยว (backend)

**ชั้น:** backend · **ต้องเสร็จก่อน:** R8.6 · **ไฟล์ที่แก้ได้:** `app/services/kong/change_applier.rb` (ลบ `execute_pr!` ย้าย helper ที่ submitter ใช้ไปไว้ใน `ChangesetRenderer`/`PrBody`), `app/controllers/change_plans_controller.rb` (`apply` บน plan PR → redirect ไป changeset + alert), `app/controllers/api/v1/change_plans_controller.rb` (`kong_apply` บน plan PR → 403 `"submit changeset <id> from the Kongsole web UI -- agents can add items but only a person submits"`), `mcp/src/tools.ts` (description ของ `kong_plan`/`kong_apply`), `spec/services/kong/change_applier_spec.rb` (ย้าย example PR mode ที่ยังมีคุณค่าไป `changeset_submitter_spec.rb`), `spec/requests/api/v1/change_plans_spec.rb`, `spec/requests/change_plans_spec.rb`, `mcp/src/tools.test.ts`

- [x] **Step 1: test**

```ruby
it "refuses to apply a PR-mode plan on its own, without touching git" do
  plan = create(:change_plan, apply_mode: "pr", status: "pending", changeset: create(:changeset))
  expect(Kong::GitClient).not_to receive(:new)
  expect { Kong::ChangeApplier.new(change_plan: plan, client: nil, actor_username: "a").call }
    .to raise_error(Kong::ChangeGuardrails::Violation, /changeset/)
end
```
+ API: `kong_apply` → 403 ข้อความตามข้างบน, plan ยัง pending

- [x] **Step 2:** FAIL → implement → PASS
- [x] **Step 3:** ตรวจว่า example PR เดิมทั้งหมดใน `change_applier_spec.rb` ถูกย้ายหรือแทนด้วย example เทียบเท่าใน submitter (ห้ามลดความคุ้มครอง: select_tags ว่าง, round-trip, admin path, cert placeholder, failure scrub, git token scrub) — ทำตารางเทียบในข้อความ commit
- [x] **Step 4:** suite 0 failures · vitest ผ่าน · Commit `refactor(R8.7): PR mode writes only through changesets`

---

### Task R8.8: controller ของ changeset + view ตั้งต้น (backend)

**ชั้น:** backend · **ต้องเสร็จก่อน:** R8.7 · **ไฟล์ที่แก้ได้:** Create `app/controllers/changesets_controller.rb`, `app/controllers/changeset_items_controller.rb`, `app/views/changesets/{index,show,preview}.html.erb` (ขั้นต่ำ: ตาราง/รายการ/ฟอร์ม, ไม่มีการตกแต่ง), `spec/requests/changesets_spec.rb`; Modify `config/routes.rb`, `app/controllers/application_controller.rb` (`current_open_changeset`), `app/controllers/change_plans_controller.rb` (`index` → redirect ไป `changesets_path` เมื่อ connection เป็น PR), `app/views/change_plans/show.html.erb` (render "In changeset #N" + link เท่านั้น)

- [x] **Step 1: test**

```ruby
require "rails_helper"

RSpec.describe "Changesets", type: :request do
  include SignInHelper
  include BareGitRepo

  let(:repo) { bare_git_repo(path: "uat/kong.yaml", select_tags: %w[managed-by-kongctl]) }
  let(:connection) do
    pr_connection_for(repo, path: "uat/kong.yaml", select_tags: %w[managed-by-kongctl]).tap { _1.update!(admin_url: "https://kong.test") }
  end
  let(:changeset) { create(:changeset, kong_connection: connection, base_git_sha: head_sha(repo)) }

  def add_item(name, position)
    create(:change_plan, changeset: changeset, kong_connection: connection, position: position, apply_mode: "pr",
      status: "pending", operation: "create", entity_type: "service", provisional_kong_id: SecureRandom.uuid,
      after: { "name" => name, "host" => "#{name}.internal", "tags" => %w[managed-by-kongctl] })
  end

  before do
    sign_in_to(connection, access: :ro) # uat -> rank 2
    stub_request(:get, "https://kong.test/").to_return(status: 200, body: { version: "3.7.1" }.to_json) # re-auth probe
    allow(Kong::DeckCli).to receive(:validate).and_return(true)
    allow(Kong::DeckCli).to receive(:diff).and_return({ "changes" => { "creating" => [], "updating" => [], "deleting" => [] } })
  end

  it "shows the open changeset's items and removes one" do
    keep = add_item("billing", 1)
    drop = add_item("ledger", 2)

    get changeset_path(changeset)
    expect(response.body).to include("billing", "ledger")

    delete changeset_item_path(changeset, drop)
    expect(drop.reload.status).to eq("cancelled")
    expect(changeset.items.reload).to eq([ keep ])
  end

  it "submits only with the retyped connection name and password at rank >= 2" do
    add_item("billing", 1)
    post submit_changeset_path(changeset), params: { confirm_env_name: "wrong", password: "pw" }
    expect(changeset.reload).to be_open
    post submit_changeset_path(changeset), params: { confirm_env_name: connection.name, password: "pw", acknowledge_drift: "1" }
    expect(changeset.reload.status).to eq("submitted")
  end

  it "accepts a pasted PR URL only on the project's git host" do
    changeset.update!(status: "submitted", branch: "kongctl/changeset-1")
    connection.project_env.project.update!(git_web_url: "https://git.example/team/repo/tree/{branch}")
    patch pr_url_changeset_path(changeset), params: { pr_url: "https://evil.example/pr/1" }
    expect(changeset.reload.pr_url).to be_nil
    patch pr_url_changeset_path(changeset), params: { pr_url: "https://git.example/team/repo/pull/7" }
    expect(changeset.reload.pr_url).to eq("https://git.example/team/repo/pull/7")
  end
end
```
(reauth ใช้กลไกเดียวกับ `ChangePlansController#reauthenticated?` — แยกเป็น concern `Reauthentication` ในไฟล์ `app/controllers/concerns/reauthentication.rb` ที่ทั้งสอง controller ใช้)

- [x] **Step 2:** FAIL → implement → PASS · suite 0 failures
- [x] **Step 3:** Commit `feat(R8.8): changeset pages -- list, preview, remove item, submit, record PR URL`

---

### Task R8.9: หน้า changeset (UI)

**ชั้น:** UI · **ต้องเสร็จก่อน:** R8.8, R3.4 · **ไฟล์ที่แก้ได้:** `app/views/changesets/*`, `app/views/change_plans/show.html.erb` (ส่วน "In changeset"), `app/views/layouts/application.html.erb` (nav "Changeset" + จำนวนรายการจาก `current_open_changeset`; ซ่อนใน direct mode — แก้ข้อสังเกตเดิม "Pending PRs บน direct"), `app/helpers/changesets_helper.rb` (create), `app/javascript/controllers/copy_controller.js` (create — ปุ่มคัดลอก PR body), `app/assets/tailwind/application.css`, `config/locales/hints.en.yml`, `spec/requests/ui_snapshots_spec.rb`, `spec/requests/consistency_spec.rb` (assertion)

**คำสั่ง:** `/impeccable shape changeset review page` (ยึด `UI-DESIGN.md` §Review page: summary strip, diff table/`.disclosure`, action bar sticky, env loudness) → `/impeccable onboard` (changeset ว่าง: "Changes to <project/env> collect here…") → `/impeccable clarify` → `/impeccable harden`

- [x] **Step 1:** assertion (ก่อน): หน้า show มี (ก) รายการเรียงตามลำดับพร้อม operation/type/name และปุ่ม Remove ต่อแถว, (ข) ลิงก์ "Preview YAML diff", (ค) ถ้ามี drift แสดง `hints.risks.changeset_drift.title` และ checkbox acknowledge, (ง) ผล CiGate เป็นคำ (`Clear` / `Blocked`), (จ) หลัง submit: ลิงก์ branch, ปุ่ม "Copy PR description", ฟอร์ม PR URL
- [x] **Step 2:** FAIL → ทำ UI · YAML diff แสดงเป็น `<pre>` ที่แยกบรรทัด +/− ด้วยสัญลักษณ์และสี (ไม่ใช่สีอย่างเดียว) · action bar ใช้ `.btn-env` ที่ rank ≥ 2
- [x] **Step 3:** PASS · snapshots: changeset-empty, changeset-open, changeset-preview, changeset-blocked, changeset-submitted · detect · ภาพหน้าจอ 390/1280
- [x] **Step 4:** Commit `feat(R8.9): changeset review page with diff preview, drift, gate and PR hand-off`

**เกณฑ์ detect:** ไม่มี finding หลักเพิ่มจาก baseline

---

### Task R8.10: ตรวจ flow จริง (verification)

**ชั้น:** — · **ต้องเสร็จก่อน:** R8.1–R8.9 · ต้องติดตั้ง decK (1.51.1 หรือ 1.66.1) หรือตั้ง `DECK_BIN`

- [x] `bin/rails kong:seed_config_repo` (repo ของ `local/uat`) → login `local/uat` (ro)
- [x] เพิ่ม 3 รายการ: update tag ของ service ที่มีใน YAML, create service ใหม่, create route ใต้ service ใหม่ (หลัง R2) → ปิด browser → เปิดใหม่ รายการยังอยู่
- [x] Remove 1 รายการ → Preview: diff ถูก, gate Clear · push commit ว่างเข้า repo แล้ว preview อีกครั้ง → drift แสดง "1 commit"
- [x] Submit (พิมพ์ชื่อ + รหัสผ่าน + ยืนยัน drift) → branch `kongctl/changeset-<id>` มี commit เดียว, trailer ถูก, YAML round-trip (`bundle exec rails runner 'Kong::DeckDocument.verify_input!(File.read(...))'`)
- [x] ลอง item ที่ลบ 4 service → Blocked ด้วย threshold 3, ไม่มี branch
- [x] ยืนยัน compose Kong ไม่มี request เขียนจาก Kongsole: `docker compose logs kong-1 | grep -E '"(POST|PATCH|PUT|DELETE)'` ช่วงทดสอบ = ว่าง
- [x] ภาพหน้าจอทุกสถานะ

### ผลตรวจ R8.10 (2026-09-25, compose ในเครื่อง: Kong 3.7.1 × 2 node, decK จริง, Edge headless)

- [x] `kong:seed_config_repo` → `storage/config_repos/uat.git` · baseline: service `r8-orders` (tag `managed-by-kongctl`) ใน Kong ผ่าน `local/dev` และใน YAML
- [x] login `local/uat` ด้วย `ro-kongctl` (`jakkapat` ไม่อยู่ใน ACL ของ route ro — ถูกต้อง) · Sync (GET) · แก้ tag ของ `r8-orders` ผ่าน UI → "In changeset #2 as item 1", หน้า plan ไม่มี Apply ·
  เพิ่มผ่าน planner แบบ agent (เส้นทางเดียวกับ `kong_plan`): create `r8-billing`, create route `r8-billing-v1` ใต้ provisional id ของ `r8-billing`, create `r8-scratch` ·
  เสนอแก้ `r8-orders` ซ้ำ → ถูกปฏิเสธ "already in this changeset" (R8.2 จริง)
- [x] context browser ใหม่ (ปิด-เปิด) → 4 รายการยังอยู่ · nav "Changeset 4" · Remove `r8-scratch` → 3 รายการ
- [x] Review: decK validate + diff จริง · gate Clear · diff: route `r8-billing-v1` อยู่ใต้ `r8-billing` ใน YAML เดียวกัน (Review Focus 1) · drift "No change"
- [x] push commit ว่างเข้า `main` → review อีกครั้ง: "Changed · git: 1 commit pushed to the base branch since this began" + checkbox
- [x] Submit (พิมพ์ `local/uat` + รหัสผ่าน + ยืนยัน drift) → `kongctl/changeset-2` มี **1 commit** บน `main` ล่าสุด · trailer `Changeset: 2` / `Plans: 53, 54, 55`
  (ไม่มี `Changed-by` เพราะ `ro-kongctl` เป็น personal ไม่มี operator — ถูกต้อง) · YAML round-trip byte-exact · `_info.select_tags` = `managed-by-kongctl` · decK diff จริง: creating 2, updating 1, deleting 0
- [x] Blocked: สร้าง 4 service tag managed ใน Kong ผ่าน `local/dev` ที่ไม่มีใน YAML + changeset ใหม่ 1 รายการ → gate "Blocked · deletes 4 entities, over the threshold of 3", ไม่มีฟอร์ม submit ·
  POST submit ตรงๆ → ปฏิเสธ, changeset ยัง Open, ไม่มี branch `kongctl/changeset-3`
- [x] Kong logs ของทั้งสอง node ช่วง uat: request ที่ไม่ใช่ GET จาก `ro-kongctl` มีแค่ access probe ตอน login (`PATCH /routes/0000…` → router 404) — ไม่มีอะไรถึง Admin API
- [x] ภาพหน้าจอ 390/1280: changeset open, review, drift, blocked, submitted, list — ไม่มี horizontal scroll
- [x] credential: `log/development.log` + log ของ server ไม่มี `Authorization` / `Basic <b64>` / password / PEM / token ใน URL
- [x] ลบข้อมูลทดสอบ: service `r8-del-1..4`, `r8-orders` ใน Kong (ผ่าน `local/dev`) · changeset 3, plan 9, audit 3 ใน DB dev

**เจอระหว่างตรวจ:** (1) dev server ที่เปิดค้างไว้จาก session ก่อน รัน `git` ไม่ได้ (ออกโดยไม่มีข้อความ) → restart server แล้วปกติ ·
(2) บั๊ก: git ที่ล้มโดยไม่ใช่เรื่องเครือข่ายถูกอธิบายว่า "Could not reach this connection" → แก้แล้ว `4fc9f8d` พร้อม test ·
(3) นอก R8 (M5c): update service ที่ YAML เขียนแค่ `url` ทำให้ไฟล์ได้ field ที่ Kong ขยายเพิ่ม (`host`/`port`/timeouts) มาด้วย ·
(4) หน้า review ของ changeset ที่ submit แล้วยังเปิดได้ (แสดง drift โดยไม่มีรายการ)

## Final review (2026-09-25, reviewer แยก บน Opus)

ไม่มี Critical · Important 6 ข้อ + ยกระดับ 2 ข้อจาก Minor → แก้ในรอบเดียว (commit `fix(R8 review #1)` และ `fix(R8 review)`), ทุกข้อมี test ที่เห็น RED ก่อน:
#1 update เขียนเฉพาะ field ที่เปลี่ยนและปฏิเสธ field ที่ git เปลี่ยนไปแล้ว · #2 lock แถว changeset ตอน submit / เพิ่ม / ลบ / abandon และ PR body ตรงกับ YAML ·
#3 lock working copy ต่อ connection (advisory lock) + ไม่ prefetch หน้า review · #4 delete ที่ rank ≥ 2 หรือ protected ต้องพิมพ์ชื่อ entity อีกครั้ง ·
#6 placeholder `DECK_` ในไฟล์เพิ่มของ env · #9 อ่าน head ของ repo นอก transaction + timeout 15 วินาที · #14 ขั้นตอน rollback ของ migration R8 ใน `00-roadmap.md`

**ยังไม่ได้ทำ — รอเจ้าของงานตัดสิน:** #5 "แก้รายการ" (ฟอร์มที่ส่ง `replaces_plan_id`) — ต้องมีฟอร์มต่อชนิด entity ซึ่งฟอร์ม service/route เป็นของ R2 ·
ตอนนี้ข้อความปฏิเสธบอกทางที่ใช้ได้จริง: "remove that item first, then propose the change again"
Minor ที่เลื่อนไว้: parent ใน attributes ข้าม admin-path check (ปลอดภัยเพราะ admin service ไม่อยู่ใน git) · submit ไม่ตรวจซ้ำว่ายังเป็น PR mode ·
ล้มหลัง push แล้วบอก "Nothing was pushed" · `pr_url` รับบน changeset ที่ไม่ได้ submit และ remove/abandon/pr_url ไม่มี audit ·
audit ของ submit ปน actor_kind ของผู้เสนอกับชื่อผู้ submit · หน้า review ของ changeset ที่ submit แล้วยังเปิดได้ · strip 3 ช่องที่ 390px เหลือช่องว่าง ·
หัวข้อ hint network_* บอก "Kong did not answer" แม้เป็น git host

## เกณฑ์ปิดงาน R8

- [ ] เกณฑ์ใน `R8-pr-mode-changeset.md` (ฉบับแก้ §C9) ครบ พร้อมหลักฐาน — **ครบยกเว้น "แก้รายการ"** (ดู, ลบ, ยังอยู่หลังปิด browser, preview diff, block admin path + threshold,
  PR body + `Changed-by:`, ตรวจ drift, ลิงก์ branch + คัดลอก PR body + วาง URL, CiGate ก่อน push, round-trip byte-exact, R3 — มีหลักฐานใน R8.1–R8.10) · "แก้" รอคำตัดสิน #5
- [x] migration 2 ตัว up/down ผ่าน (R8.1: migrate → rollback STEP=2 → migrate) · ขั้นตอน rollback ใน `00-roadmap.md` #5, #6
- [x] test "no write call" ผ่านทั้ง planner และ submitter · compose: request ที่ไม่ใช่ GET จาก `ro-kongctl` มีแค่ access probe ตอน login (router 404)
- [x] `bundle exec rspec` **1174/0** · vitest **31/31** · detect: หน้าเดิมไม่เพิ่ม (60 → 74 ทั้งหมดอยู่ใน 5 หน้าใหม่ และเป็นชนิดที่ baseline มีจาก component เดิม) ·
  `hints:todo`: เพิ่ม 3 key `hints.errors.git_auth_failed.*` (To Edit) + 2 เดิมของ R3.7
- [x] ไม่มี credential หลุด: `failure_reason`/`pr_body` scrub PEM + token ใน git URL (test) · log dev + server ช่วง R8.10 ไม่มี `Authorization` / `Basic <b64>` / password / PEM
