# R5 — Project understanding Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** หน้า overview ต่อ project (env ตามลำดับ, apply_mode, สถานะ connection, จำนวน entity ต่อชนิด), request tracer (host + path + method → route → service → plugin ตามลำดับที่ทำงาน) และ notes ที่ทีมเขียน (`config/projects/<key>.md` ใน repo Kongsole) — ส่วนที่มาจาก Kong อ่าน read-model เท่านั้น

**Architecture:** query object `ProjectOverview` + `Kong::RouteMatcher` (ประมาณ router แบบ traditional ของ Kong) + `Kong::PluginChain` (ความเฉพาะเจาะจงของ scope + priority จาก `available_on_server`) — ไม่มี HTTP ไป Kong เลย (มี test ยืนยัน) · notes render ด้วย `commonmarker` แบบ safe (ไม่มี raw HTML)

**Tech Stack:** Rails 8.1, gem `commonmarker` (ใหม่), Stimulus, RSpec

**Spec:** `docs/requirements/R5-project-understanding.md` (+ `design-amendments.md` §C6, §A4), `docs/plans/00-roadmap.md` (Q22)

## Global Constraints

- ส่วนที่มาจาก Kong อ่าน read-model เท่านั้น — ไม่มี request ไป Kong ใน controller/service ของ R5 (test ด้วย `WebMock` ที่ไม่ stub อะไร)
- หน้า overview/tracer เปิดได้โดยไม่ต้อง login (อ่าน DB ในเครื่องเท่านั้น; ข้อมูลผ่าน redactor แล้ว) — **ตัดสินใจใน plan นี้ ให้เจ้าของงานยืนยันตอนอนุมัติ**
- notes: markdown ไม่มี raw HTML, ลิงก์เฉพาะ http(s)/mailto; ไฟล์ต้องอยู่ใต้ `config/projects/` เท่านั้น (key ผ่าน `Project::KEY_FORMAT`)
- tracer บอกทุกครั้งว่าเป็น "approximation of Kong's traditional router" และไม่รองรับ expressions router, headers, SNI
- entity admin path แสดงพร้อม mark เดิม (`.entity-row--admin`)

## Review Focus

1. route regex ที่ Ruby compile ไม่ได้ (PCRE เฉพาะทาง) → ข้ามพร้อมหมายเหตุ ไม่ 500 — test ใน R5.2
2. path ที่ match สอง route (prefix `/api` และ `/api/v1`) → เลือกตัวที่ยาวกว่า — test ใน R5.2
3. plugin ชื่อเดียวกันที่ global และ route → แสดงเฉพาะตัว route (เฉพาะเจาะจงกว่า) และบอกว่าทับตัว global — test ใน R5.3
4. connection ที่ไม่เคย sync → overview บอก "Never synced" ไม่ใช่ 0 entity — test ใน R5.1
5. notes มี `<script>` หรือ `javascript:` link → ไม่ถูก render — test ใน R5.4

---

## Spec ที่ตกลงแล้ว

- **Overview** `/projects/:key`: ตาราง env ตาม `position` — env chip, rank label, apply_mode label, สถานะ connection (`last_status` + เวลา), sync ล่าสุด (min `synced_at`), จำนวน service/route/plugin/consumer/upstream/certificate; ลิงก์ Log in ต่อ env; ส่วน notes; ลิงก์ไป tracer
- **Tracer** `/projects/:key/trace?env=<name>&host=&path=&method=GET`: ผลลัพธ์ = route ที่ match (+ เหตุผล: host/path/method ที่ match), service (host:port/path), plugin chain ตามลำดับที่ทำงาน (priority สูงก่อน) พร้อม scope และ enabled; route ตัวอื่นที่ match แต่แพ้ (พร้อมเหตุผล); ไม่มี match → "Kong would answer 404 no Route matched"
- **Router approximation:** match = host (exact ไม่สนตัวพิมพ์ / wildcard / route ไม่มี hosts = ทุก host) ∧ method (ว่าง = ทุก method) ∧ path (prefix หรือ regex `~` anchored ต้นทาง); ลำดับ: จำนวนเงื่อนไขที่ route ตั้ง (hosts, methods, paths) มากก่อน → regex ก่อน prefix โดย `regex_priority` สูงก่อน → prefix ยาวก่อน → `kong_created_at` เก่าก่อน
- **Plugin precedence:** ชื่อเดียวกันหลาย scope → route+service > route > service > global (consumer ไม่รู้ตอน trace → แสดง plugin ระดับ consumer แยกเป็น "applies only for consumer X")
- **Notes:** `config/projects/<key>.md` · ไม่มีไฟล์ → empty state บอกวิธีสร้าง (`bin/rails kong:project_notes[<key>]` สร้าง skeleton: Business flow / Owners / Who to contact / Before you change anything) และแก้ผ่าน PR ใน repo Kongsole

## Contract UI ↔ backend

| backend ให้ | รายละเอียด |
|---|---|
| routes | เพิ่ม `show` ใน `resources :projects, param: :key` ของ R1 · `get "projects/:key/trace" => "project_traces#show", as: :project_trace` |
| `@overview` | `ProjectOverview::Row(env:, connection:, status:, last_connected_at:, synced_at:, counts: Hash<String,Integer>)` ต่อ env |
| `@notes_html` | `ActiveSupport::SafeBuffer` หรือ nil · `@notes_path` = `"config/projects/<key>.md"` |
| `@trace` | `Kong::RouteMatcher::Result(route:, service:, matched_on:, losers: [{route:, reason:}], plugins: [Kong::PluginChain::Step(plugin:, scope:, priority:, enabled:, overrides:)], consumer_plugins: [...], skipped_regex: [route names])` หรือ nil ก่อนค้นหา |
| trace params | `env` (ชื่อ env ของ project), `host`, `path` (ต้องขึ้นต้น `/`), `method` (ค่าใน `RouteForm::METHODS`) → error ต่อ field ใน `@trace_errors` |

---

### Task R5.1: `ProjectOverview` (backend)

**ชั้น:** backend · **ต้องเสร็จก่อน:** R1 · **ไฟล์ที่แก้ได้:** Create `app/queries/project_overview.rb`, `spec/queries/project_overview_spec.rb`

- [ ] **Step 1: test**

```ruby
require "rails_helper"

RSpec.describe ProjectOverview do
  let(:project) { create(:project, key: "project-a") }
  let!(:dev) { create(:project_env, project: project, name: "dev", position: 1) }
  let!(:uat) { create(:project_env, project: project, name: "uat", position: 2, apply_mode: "pr", source: "registry") }
  let!(:dev_conn) { create(:kong_connection, project_env: dev, last_status: "ok") }

  it "lists envs in order with counts per entity type from the read-model" do
    create_list(:kong_entity, 2, kong_connection: dev_conn, entity_type: "service")
    create(:kong_entity, kong_connection: dev_conn, entity_type: "route")
    create(:kong_entity, kong_connection: dev_conn, entity_type: "service", deleted_at: Time.current)

    rows = described_class.new(project).rows
    expect(rows.map { _1.env.name }).to eq(%w[dev uat])
    expect(rows.first.counts).to include("service" => 2, "route" => 1, "plugin" => 0)
  end

  it "says an env has no connection, and a connection that never synced has no counts" do
    rows = described_class.new(project).rows
    expect(rows.last.connection).to be_nil
    expect(rows.first.synced_at).to be_nil
  end

  it "never calls Kong" do
    described_class.new(project).rows
    expect(a_request(:any, //)).not_to have_been_made
  end
end
```

- [ ] **Step 2:** FAIL → implement (หนึ่ง query `group(:kong_connection_id, :entity_type).count` — ไม่มี N+1) → PASS · Commit `feat(R5.1): project overview from the read-model`

---

### Task R5.2: `Kong::RouteMatcher` (backend)

**ชั้น:** backend · **ต้องเสร็จก่อน:** R5.1 · **ไฟล์ที่แก้ได้:** Create `app/services/kong/route_matcher.rb`, `spec/services/kong/route_matcher_spec.rb`

**Interfaces:** `Kong::RouteMatcher.call(connection:, host:, path:, method:) -> Result` (ดู contract; `plugins` เติมโดย R5.3)

- [ ] **Step 1: test**

```ruby
require "rails_helper"

RSpec.describe Kong::RouteMatcher do
  let(:connection) { create(:kong_connection) }
  let(:service) { create(:kong_entity, kong_connection: connection, entity_type: "service", name: "billing",
    data: { "name" => "billing", "host" => "billing.internal", "port" => 8080, "protocol" => "http" }) }

  def route(name, created: Time.utc(2026, 1, 1), **data)
    create(:kong_entity, kong_connection: connection, entity_type: "route", name: name, kong_created_at: created,
      parent_type: "service", parent_kong_id: service.kong_id,
      data: { "name" => name, "hosts" => [], "paths" => [], "methods" => [], "regex_priority" => 0 }.merge(data.stringify_keys))
  end

  def trace(path, host: "api.example.com", method: "GET")
    described_class.call(connection: connection, host: host, path: path, method: method)
  end

  it "picks the longest matching prefix" do
    route("api", paths: %w[/api])
    route("api-v1", paths: %w[/api/v1])
    result = trace("/api/v1/invoices")
    expect(result.route.name).to eq("api-v1")
    expect(result.losers.map { _1[:route].name }).to eq(%w[api])
    expect(result.service.name).to eq("billing")
  end

  it "prefers a route that sets more conditions" do
    route("any-host", paths: %w[/api])
    route("this-host", paths: %w[/api], hosts: %w[api.example.com])
    expect(trace("/api").route.name).to eq("this-host")
  end

  it "tries regex before prefix, highest regex_priority first" do
    route("prefix", paths: %w[/api])
    route("rx", paths: [ "~/api/v[0-9]+$" ], regex_priority: 5)
    expect(trace("/api/v2").route.name).to eq("rx")
  end

  it "skips a regex Ruby cannot compile and says so" do
    route("pcre-only", paths: [ "~/api/(?<x>\\d+)(?(x)a|b)" ])
    result = trace("/api/1")
    expect(result.skipped_regex).to eq(%w[pcre-only])
  end

  it "answers no route for a method the route does not allow" do
    route("reads", paths: %w[/api], methods: %w[GET])
    expect(trace("/api", method: "POST").route).to be_nil
  end

  it "reads only the read-model" do
    route("api", paths: %w[/api])
    trace("/api")
    expect(a_request(:any, //)).not_to have_been_made
  end
end
```

- [ ] **Step 2:** FAIL → implement (regex: `Regexp.new("\\A(?:#{path.delete_prefix('~')})", timeout: 0.1)` — timeout ต่อ regex ไม่ใช่ `Regexp.timeout` ทั้ง process; `RegexpError`/`Regexp::TimeoutError` → skipped) → PASS
- [ ] **Step 3:** Commit `feat(R5.2): approximate Kong's route matching from the read-model`

---

### Task R5.3: `Kong::PluginChain` (backend)

**ชั้น:** backend · **ต้องเสร็จก่อน:** R5.2 · **ไฟล์ที่แก้ได้:** Create `app/services/kong/plugin_chain.rb`, `spec/services/kong/plugin_chain_spec.rb`; Modify `app/services/kong/route_matcher.rb` (เติม `plugins`, `consumer_plugins`)

**Interfaces:** `Kong::PluginChain.for(connection:, route:, service:) -> [Array<Step>, Array<Step>]` (ทั่วไป, เฉพาะ consumer); `Step = Struct.new(:plugin, :scope, :priority, :enabled, :overrides, keyword_init: true)`

- [ ] **Step 1: test**

```ruby
require "rails_helper"

RSpec.describe Kong::PluginChain do
  let(:connection) { create(:kong_connection, plugins_available: { "available_on_server" => {
    "rate-limiting" => { "priority" => 910 }, "key-auth" => { "priority" => 1250 }, "cors" => { "priority" => 2000 } } }) }
  let(:service) { create(:kong_entity, kong_connection: connection, entity_type: "service") }
  let(:route) { create(:kong_entity, kong_connection: connection, entity_type: "route", parent_type: "service", parent_kong_id: service.kong_id) }

  def plugin(name, scope: {}, enabled: true)
    create(:kong_entity, kong_connection: connection, entity_type: "plugin", name: name, enabled: enabled,
      data: { "name" => name, "enabled" => enabled }.merge(scope))
  end

  it "orders plugins by Kong priority, highest first, across scopes" do
    plugin("rate-limiting")
    plugin("key-auth", scope: { "service" => { "id" => service.kong_id } })
    plugin("cors", scope: { "route" => { "id" => route.kong_id } })
    steps, = described_class.for(connection: connection, route: route, service: service)
    expect(steps.map { _1.plugin.name }).to eq(%w[cors key-auth rate-limiting])
  end

  it "keeps only the most specific instance of the same plugin, naming what it overrides" do
    plugin("rate-limiting")
    plugin("rate-limiting", scope: { "route" => { "id" => route.kong_id } })
    steps, = described_class.for(connection: connection, route: route, service: service)
    expect(steps.map(&:scope)).to eq(%w[route])
    expect(steps.first.overrides).to eq(%w[global])
  end

  it "lists consumer-scoped plugins apart, since the tracer does not know the consumer" do
    consumer = create(:kong_entity, kong_connection: connection, entity_type: "consumer", name: "partner-x")
    plugin("rate-limiting", scope: { "consumer" => { "id" => consumer.kong_id } })
    steps, consumer_steps = described_class.for(connection: connection, route: route, service: service)
    expect(steps).to be_empty
    expect(consumer_steps.first.scope).to eq("consumer")
  end

  it "shows disabled plugins as disabled rather than hiding them" do
    plugin("cors", enabled: false)
    steps, = described_class.for(connection: connection, route: route, service: service)
    expect(steps.first.enabled).to be(false)
  end
end
```

- [ ] **Step 2:** FAIL → implement → PASS · Commit `feat(R5.3): the plugin chain a traced request would run`

---

### Task R5.4: project notes (backend)

**ชั้น:** backend · **ต้องเสร็จก่อน:** R1 · **ไฟล์ที่แก้ได้:** Modify `Gemfile`, `Gemfile.lock` (`gem "commonmarker", "~> 2.0"`); Create `app/services/project_notes.rb`, `config/projects/.keep`, `spec/services/project_notes_spec.rb`; Modify `lib/tasks/kong.rake` (`kong:project_notes[key]`)

**Interfaces:** `ProjectNotes.new(project, dir: Rails.root.join("config/projects")).html -> SafeBuffer | nil`; `#relative_path`

- [ ] **Step 1: test**

```ruby
require "rails_helper"

RSpec.describe ProjectNotes do
  let(:dir) { Rails.root.join("tmp/spec_project_notes").tap { FileUtils.mkdir_p(_1) } }
  let(:project) { create(:project, key: "project-a") }

  it "renders the project's markdown" do
    File.write(dir.join("project-a.md"), "# Billing flow\n\nOwner: **Team A**")
    expect(described_class.new(project, dir: dir).html).to include("<h1>Billing flow</h1>", "<strong>Team A</strong>")
  end

  it "drops raw HTML and javascript: links" do
    File.write(dir.join("project-a.md"), "<script>alert(1)</script>\n\n[x](javascript:alert(1))")
    html = described_class.new(project, dir: dir).html
    expect(html).not_to include("<script>")
    expect(html).not_to include("javascript:")
  end

  it "returns nil when the project has no notes yet" do
    expect(described_class.new(create(:project, key: "project-x"), dir: dir).html).to be_nil
  end
end
```

- [ ] **Step 2:** FAIL → `bundle add commonmarker` → `bundle exec bundler-audit check --update` สะอาด → implement (`Commonmarker.to_html(text, options: { render: { unsafe: false } })` แล้วลบ `href` ที่ไม่ใช่ http/https/mailto) → PASS
- [ ] **Step 3:** rake `kong:project_notes[project-a]` สร้าง skeleton ถ้ายังไม่มี (ไม่เขียนทับ)
- [ ] **Step 4:** Commit `feat(R5.4): team-written project notes from config/projects, rendered safely`

---

### Task R5.5: controllers + view ตั้งต้น (backend)

**ชั้น:** backend · **ต้องเสร็จก่อน:** R5.1–R5.4 · **ไฟล์ที่แก้ได้:** Modify `app/controllers/projects_controller.rb` (`show`), `config/routes.rb`; Create `app/controllers/project_traces_controller.rb`, `app/views/projects/show.html.erb`, `app/views/project_traces/show.html.erb` (ขั้นต่ำ), `spec/requests/projects_overview_spec.rb`, `spec/requests/project_traces_spec.rb`

- [ ] **Step 1: test**

```ruby
# spec/requests/project_traces_spec.rb
require "rails_helper"

RSpec.describe "Project trace", type: :request do
  let(:project) { create(:project, key: "project-a") }
  let(:env) { create(:project_env, project: project, name: "dev", position: 1) }
  let(:connection) { create(:kong_connection, project_env: env) }

  it "traces a request without logging in and without calling Kong" do
    service = create(:kong_entity, kong_connection: connection, entity_type: "service", name: "billing", data: { "host" => "b" })
    create(:kong_entity, kong_connection: connection, entity_type: "route", name: "billing-v1", parent_type: "service",
      parent_kong_id: service.kong_id, data: { "paths" => %w[/billing], "hosts" => [], "methods" => [] })

    get project_trace_path(project.key, env: "dev", host: "api.example.com", path: "/billing/1", method: "GET")

    expect(response.body).to include("billing-v1", "billing")
    expect(a_request(:any, //)).not_to have_been_made
  end

  it "reports field errors for a path without a leading slash" do
    get project_trace_path(project.key, env: "dev", host: "x", path: "billing", method: "GET")
    expect(response).to have_http_status(:unprocessable_entity)
  end

  it "404s for an unknown project key" do
    get project_trace_path("nope")
    expect(response).to have_http_status(:not_found)
  end
end
```
+ `projects_overview_spec.rb`: overview แสดง env ทั้งหมดตามลำดับ, notes html, และ empty state เมื่อไม่มี notes

- [ ] **Step 2:** FAIL → implement (`skip_before_action` ไม่มี `require_session!` ใน 2 controller นี้) → PASS · suite 0 failures
- [ ] **Step 3:** Commit `feat(R5.5): project overview and request tracer pages`

---

### Task R5.6: หน้า overview (UI)

**ชั้น:** UI · **ต้องเสร็จก่อน:** R5.5, R3.4 · **ไฟล์ที่แก้ได้:** `app/views/projects/show.html.erb`, `app/views/projects/_env_row.html.erb` (create), `app/views/projects/_notes.html.erb` (create), `app/views/connections/_project.html.erb` (ลิงก์ไป overview), `app/views/layouts/application.html.erb` (nav "Project" เมื่อ login), `app/assets/tailwind/application.css` (สไตล์ `.prose-notes` สำหรับ markdown — ใช้ token เดิม), `config/locales/hints.en.yml`, `spec/requests/ui_snapshots_spec.rb`

**คำสั่ง:** `/impeccable shape project overview` → `/impeccable onboard` (notes ว่าง: บอกคำสั่ง rake + ขั้น PR) → `/impeccable harden` (notes ภาษาไทยยาว, env 6+ แถว, 390px)

- [ ] **Step 1:** assertion (ก่อน): overview มี env ตามลำดับ, "Never synced" เมื่อไม่มี sync, ลิงก์ "Trace a request"; notes ที่มีภาษาไทยแสดงครบ (snapshot มี fixture ภาษาไทย)
- [ ] **Step 2:** FAIL → ทำ UI · PASS · snapshot · detect · Commit `feat(R5.6): project overview page`

---

### Task R5.7: หน้า tracer (UI)

**ชั้น:** UI · **ต้องเสร็จก่อน:** R5.6 · **ไฟล์ที่แก้ได้:** `app/views/project_traces/show.html.erb`, `app/views/project_traces/_result.html.erb` (create), `app/assets/tailwind/application.css`, `config/locales/hints.en.yml` (`hints.fields.trace.*`, `hints.pages.trace.intro`, `hints.risks.trace_approximation`), `spec/requests/ui_snapshots_spec.rb`

**คำสั่ง:** `/impeccable shape request tracer` → `/impeccable clarify` → `/impeccable harden`

- [ ] **Step 1:** assertion (ก่อน): ผลลัพธ์เป็นลำดับ route → service → plugins (ลำดับที่ทำงาน) ที่อ่านได้โดยไม่ต้องพึ่งสี; มีประโยค approximation; route ที่แพ้แสดงใน `.disclosure`; ไม่มี match แสดง "Kong would answer 404 …"
- [ ] **Step 2:** FAIL → ทำ UI (ใช้ mark `.route-match`, `.scope` เดิม; ลำดับ plugin เป็น `<ol>`) · PASS · snapshot · detect
- [ ] **Step 3:** Commit `feat(R5.7): request tracer shows route, service and plugin chain in order`

---

### Task R5.8: ตรวจรับ (verification + สคริปต์ 5 นาที)

**ชั้น:** — · **ต้องเสร็จก่อน:** R5.1–R5.7

- [ ] compose `local/dev`: สร้าง service `echo` + route `/echo` + rate-limiting (service) + cors (global) → sync → tracer `/echo/x` แสดง route echo, service echo, cors → rate-limiting ตามลำดับ priority
- [ ] `bin/rails kong:project_notes[local]` → แก้ไฟล์ด้วยข้อความไทย/อังกฤษ → overview แสดงผล
- [ ] **สคริปต์ทดสอบ 5 นาที (เจ้าของงานเป็นผู้ตรวจ):** ให้คนที่ไม่เคยดู project `local` ตอบภายใน 5 นาทีโดยใช้ Kongsole อย่างเดียว: "request `GET api.example.com/echo/x` ผ่าน route อะไร, ไป service ไหน (host:port), plugin ใดทำงานบ้างตามลำดับ, และใครเป็น owner" — จดเวลาและคำตอบ
- [ ] ภาพหน้าจอ 390/1280

## เกณฑ์ปิดงาน R5

- [ ] เกณฑ์ใน `R5-project-understanding.md` (ฉบับแก้ §C6) ครบ พร้อมหลักฐาน
- [ ] test "ไม่เรียก Kong" ผ่านทั้ง overview และ tracer
- [ ] `bundler-audit` สะอาดหลังเพิ่ม `commonmarker`
- [ ] `bundle exec rspec` 0 failures · detect ไม่เพิ่ม · `hints:todo` รายงาน
