# R5 — Project understanding Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** หน้า project (`/projects/:key` ของ R1.20) บอกภาพรวมของ project — env, สถานะ, จำนวน entity, sync ล่าสุด และ notes ของทีม — และ request tracer (layout B) ที่พา request หนึ่งผ่าน route → plugins → service พร้อม request ที่ service ได้รับจริง ทั้งหมดอ่านจาก read-model

**Architecture:** query `ProjectOverview` + service objects ที่ไม่มี HTTP: `Kong::RouteMatcher` (ประมาณ router `traditional_compatible`), `Kong::PluginChain` + `Kong::PluginEffects` (ลำดับ plugin และ plugin ที่อาจหยุด/เปลี่ยน request), `Kong::ForwardedRequest` (URL ที่ service ได้รับ), `Kong::RequestTrace` (รวมทั้งหมด) · ลำดับ route และกติกาต่อ path ถูกตรึงด้วย fixture ที่บันทึกจาก compose Kong จริง (R5.0) · notes render ด้วย `commonmarker` แบบ safe

**Tech Stack:** Rails 8.1, gem `commonmarker ~> 2.0` (ใหม่), RSpec + WebMock, Hotwire/Stimulus, Tailwind, `/impeccable`

**Spec:** `docs/superpowers/specs/2026-09-27-r5-project-understanding-design.md` (อนุมัติ 2026-09-27) · requirement `docs/requirements/R5-project-understanding.md` + `design-amendments.md` §C6 · UI prototype ที่อนุมัติ: https://claude.ai/artifact/PStVYPrCgaS7hYWwF8GfrV (boards *Overview desktop*, *Overview phone*, *Tracer B (chosen)*, *Tracer B step 4 — service only*; Tracer A/C ไม่ใช้)

## Global Constraints

- ส่วนที่มาจาก Kong อ่าน read-model เท่านั้น — ไม่มี request ไป Kong ใน controller/query/service ของ R5 (request spec ใช้ WebMock ที่ไม่ stub อะไร: `expect(a_request(:any, //)).not_to have_been_made`)
- หน้า overview และ tracer เปิดได้โดยไม่ต้อง login
- สถานะ connection = ผล login ล่าสุด + เวลา; `unreachable` แสดง `network_note` ของ project
- notes: markdown ไม่มี raw HTML, ลิงก์เฉพาะ http/https/mailto, ไฟล์อยู่ใต้ `config/projects/` เท่านั้น, key ผ่าน `Project::KEY_FORMAT`
- entity admin path แสดงพร้อม mark เดิม (`.entity-row--admin` / tag "admin path")
- tracer ไม่แสดง config ของ plugin ยกเว้น `status_code` และ `message` ของ `request-termination`
- ประโยค approximation: "An approximation of Kong's router (traditional_compatible), from <env>'s sync at <time>. Headers, SNI and expressions routes are not considered."
- แต่ละจุดของ tracer อธิบายเฉพาะ setting ของตัวเอง: จุด 2 route (ตัด path, query, Host header) · จุด 3 plugins + note · จุด 4 service เท่านั้น
- plugin ไม่ถูกจำลอง — ถูกเรียกชื่อ ("Kongsole names these plugins; it does not run them.")
- ตรวจกับ compose ในเครื่องเท่านั้น (CLAUDE.md กฎ 7)

## Review Focus

1. plugin ชื่อเดียวกัน: ตัวที่ scope แคบกว่า **disabled** อยู่ → ตัวที่กว้างกว่าที่ enabled คือตัวที่ทำงาน (Kong ไม่โหลด plugin ที่ disabled) — test ใน R5.3
2. host ที่ผู้ใช้พิมพ์มีตัวพิมพ์ใหญ่หรือมี `:port` → ยัง match route เดิม — test ใน R5.2
3. route ที่มีหลาย path และ path แรกในรายการสั้นกว่า → ใช้ path ที่ดีที่สุดในการจัดลำดับ และตัดตาม path นั้น — test ใน R5.2
4. `request-termination` ที่ตั้ง `trigger` → เป็น "may answer" ไม่ใช่ "answers" (ตอบเฉพาะเมื่อมี header/query นั้น) — test ใน R5.3
5. path ที่มี query string → match ด้วย path ที่ไม่มี query และส่ง query ต่อไปตามเดิม — test ใน R5.6

---

## Contract UI ↔ backend

| backend ให้ | รายละเอียด |
|---|---|
| routes | ไม่เพิ่ม `projects#show` (มีแล้วจาก R1.20) · เพิ่ม `get "projects/:key/trace" => "project_traces#show", as: :project_trace` |
| `@overview` (projects#show) | `Array<ProjectOverview::Row(env:, connection:, status:, last_connected_at:, synced_at:, counts: Hash<String,Integer>)>` ตามลำดับ env |
| `@notes_html` / `@notes_path` | `ActiveSupport::SafeBuffer` หรือ nil · `"config/projects/<key>.md"` |
| `@trace_form` | `TraceForm` (attrs `env`, `http_method`, `host`, `path`; `#path_only`, `#query`, `#connection`) |
| `@trace` | `Kong::RequestTrace::Trace(connection:, synced_at:, match:, steps:, consumer_steps:, forwarded:)` หรือ nil ก่อนค้นหา |
| `@trace.match` | `Kong::RouteMatcher::Result(route:, service:, matched_on: {host:, method:, path:, regex:, matched:}, losers: [{route:, reason:}], skipped: [{route:, reason:}])` |
| `@trace.steps` / `consumer_steps` | `Array<Kong::PluginChain::Step(plugin:, scope:, priority:, enabled:, overrides:, effect:, consumer:)>` เรียงตามลำดับที่ทำงาน |
| `step.effect` | `Kong::PluginEffects::Effect(kind:, status:)` หรือ nil · kind ∈ `:may_stop :may_change :may_answer :answers :unknown` |
| `@trace.forwarded` | `Kong::ForwardedRequest::Result(route_effect:, service_effect:, answered_by:)` หรือ nil เมื่อไม่มี route/service |
| `@trace_errors` | `ActiveModel::Errors` ต่อ field → 422 |
| `@trace_envs` | env ของ project ตามลำดับ พร้อม connection และ `synced_at` (nil = ยังไม่เคย sync → เลือกไม่ได้) |

---

### Task R5.0: บันทึกพฤติกรรมจริงของ compose Kong เป็น fixture

**ชั้น:** backend (test tooling) · **ต้องเสร็จก่อน:** — · **ไฟล์ที่แก้ได้:** Create `script/kong_router_fixtures.rb`, `spec/fixtures/kong_router/ordering.json`, `spec/fixtures/kong_router/join.json`

เหตุผล: ลำดับ route และกติกาการต่อ path ในสเปก §4.2/§4.4 เป็นสมมติฐานจากเอกสาร Kong — fixture นี้คือหลักฐาน และเป็น authority ของ test ใน R5.2 และ R5.4 (ถ้าแถวใดขัดกับโค้ด ให้แก้โค้ด ไม่แก้ fixture)

- [x] **Step 1: เขียน script** (ทำงานกับ compose เท่านั้น ลบทุกอย่างที่สร้างเมื่อจบ แม้ล้มกลางทาง)

```ruby
# script/kong_router_fixtures.rb
# R5.0: records what compose Kong actually does for the R5 tracer -- which
# route wins (ordering.json) and what a service receives (join.json) -- so the
# tracer's specs test against Kong, not against our reading of its docs.
#
#   ruby script/kong_router_fixtures.rb
#
# Local compose only (CLAUDE.md rule 7). Everything it creates carries the tag
# r5-router-check and is deleted at the end, even after a failure.
#
# How a forwarded request is seen without an echo server: each join case's
# service points back at Kong's own proxy (127.0.0.1:8000) and adds the header
# x-r5-sink:1 (request-transformer); the r5-sink route matches that header
# (plus hosts and "/", so it outranks every test route) and answers with
# request-termination echo -- the echoed request is what a real service
# would have received.
require "json"
require "net/http"
require "uri"

ADMIN = URI(ENV.fetch("KONG_ADMIN", "http://localhost:8001"))
PROXY = URI(ENV.fetch("KONG_PROXY", "http://localhost:8000"))
abort "local compose only" unless [ ADMIN, PROXY ].all? { |uri| %w[localhost 127.0.0.1].include?(uri.host) }
TAG = "r5-router-check"
OUT = File.expand_path("../spec/fixtures/kong_router", __dir__)

def admin(verb, path, body = nil)
  request = Net::HTTP.const_get(verb.to_s.capitalize).new(path, "Content-Type" => "application/json")
  request.body = body.to_json if body
  response = Net::HTTP.start(ADMIN.host, ADMIN.port) { |http| http.request(request) }
  raise "#{verb} #{path} -> #{response.code} #{response.body}" unless response.code.start_with?("2")
  response.body.to_s.empty? ? {} : JSON.parse(response.body)
end

def proxy(verb, host, path)
  request = Net::HTTP.const_get(verb.to_s.capitalize).new(path, "Host" => host)
  response = Net::HTTP.start(PROXY.host, PROXY.port) { |http| http.request(request) }
  body = begin
    JSON.parse(response.body)
  rescue JSON::ParserError
    {}
  end
  [ response.code.to_i, body ]
end

def cleanup
  %w[plugins routes services upstreams].each do |collection|
    admin(:get, "/#{collection}?tags=#{TAG}&size=1000").fetch("data").each { |row| admin(:delete, "/#{collection}/#{row['id']}") }
  end
end

def route(name, service_id, **attrs)
  admin(:post, "/routes", { name: name, service: { id: service_id }, protocols: %w[http], tags: [ TAG ] }.merge(attrs))
end

def echo_on(route_id)
  admin(:post, "/plugins", name: "request-termination", route: { id: route_id }, config: { status_code: 200, echo: true }, tags: [ TAG ])
end

def loop_service(name, path)
  service = admin(:post, "/services", { name: name, protocol: "http", host: "127.0.0.1", port: 8000, tags: [ TAG ] }.merge(path ? { path: path } : {}))
  admin(:post, "/plugins", name: "request-transformer", service: { id: service["id"] }, config: { add: { headers: [ "x-r5-sink:1" ] } }, tags: [ TAG ])
  service
end

ORDER_CASES = [
  { name: "longer prefix wins", request: %w[GET /api/v1/x], routes: [ { name: "short", paths: %w[/api] }, { name: "long", paths: %w[/api/v1] } ] },
  { name: "a prefix is a plain string prefix", request: %w[GET /billingx], routes: [ { name: "billing", paths: %w[/billing] } ] },
  { name: "more conditions win", request: %w[GET /api], routes: [ { name: "paths-only", paths: %w[/api] }, { name: "with-method", paths: %w[/api], methods: %w[GET] } ] },
  { name: "regex against prefix", request: %w[GET /api/v2], routes: [ { name: "prefix", paths: %w[/api] }, { name: "regex", paths: [ "~/api/v[0-9]+$" ] } ] },
  { name: "higher regex_priority wins", request: %w[GET /api/v2], routes: [ { name: "rx-low", paths: [ "~/api/v\\d" ], regex_priority: 0 }, { name: "rx-high", paths: [ "~/api/v2" ], regex_priority: 5 } ] },
  { name: "exact host beats wildcard", host: "api.o6.r5.test", request: %w[GET /x], routes: [ { name: "wild", hosts: [ "*.o6.r5.test" ], paths: %w[/x] }, { name: "exact", hosts: [ "api.o6.r5.test" ], paths: %w[/x] } ] },
  { name: "older route wins a tie", request: %w[GET /tie], routes: [ { name: "first", paths: %w[/tie] }, { name: "second", paths: %w[/tie] } ] },
  { name: "a method the route does not allow", request: %w[POST /reads], routes: [ { name: "reads", paths: %w[/reads], methods: %w[GET] } ] },
  { name: "the best of a route's paths counts", request: %w[GET /api/v1/x], routes: [ { name: "many-paths", paths: %w[/a /api/v1] }, { name: "mid", paths: %w[/api] } ] }
].freeze

JOIN_CASES = [
  # name, service path, route path, strip_path, path_handling, request path (+ preserve_host)
  [ "v0 strip, plain", "/s", "/tv0", true, "v0", "/tv0req" ],
  [ "v1 strip, plain", "/s", "/tv1", true, "v1", "/tv1req" ],
  [ "v0 keep, plain", "/s", "/fv0", false, "v0", "/fv0req" ],
  [ "v1 keep, plain", "/s", "/fv1", false, "v1", "/fv1req" ],
  [ "v0 strip, route slash", "/s", "/tv0/", true, "v0", "/tv0/req" ],
  [ "v1 strip, route slash", "/s", "/tv1/", true, "v1", "/tv1/req" ],
  [ "v0 strip, service slash", "/s/", "/tv0", true, "v0", "/tv0/req" ],
  [ "v1 strip, service slash", "/s/", "/tv1", true, "v1", "/tv1/req" ],
  [ "strip, nothing left, no service path", nil, "/notify", true, "v0", "/notify" ],
  [ "strip, nothing left, service path", "/api", "/notify", true, "v0", "/notify" ],
  [ "keep, no service path", nil, "/ledger", false, "v0", "/ledger/entries/9" ],
  [ "regex strip", "/v2", "~/reports/\\d{4}", true, "v0", "/reports/2026/q3" ],
  [ "query passed on", "/api", "/billing/v1", true, "v0", "/billing/v1/invoices/42?status=paid" ],
  [ "preserve_host on", "/api", "/ph", true, "v0", "/ph/x", true ]
].freeze

begin
  root = admin(:get, "/")
  cleanup

  sink_service = admin(:post, "/services", name: "r5-sink", url: "http://127.0.0.1:65535", tags: [ TAG ])
  sink = route("r5-sink", sink_service["id"], hosts: [ "127.0.0.1", "*.r5.test", "r5-up" ], headers: { "x-r5-sink" => [ "1" ] }, paths: %w[/], strip_path: false)
  echo_on(sink["id"])

  ordering = ORDER_CASES.each_with_index.map do |kase, index|
    host = kase[:host] || "o#{index}.r5.test"
    target = admin(:post, "/services", name: "r5-order-#{index}", url: "http://127.0.0.1:65535", tags: [ TAG ])
    kase[:routes].each do |attrs|
      created = route("#{attrs[:name]}-#{index}", target["id"], **{ hosts: [ host ] }.merge(attrs.except(:name)))
      echo_on(created["id"])
      sleep 1.1 # Kong's created_at has one-second resolution; the tie case needs them apart
    end
    sleep 1 # router rebuild
    status, body = proxy(kase[:request][0], host, kase[:request][1])
    winner = body.dig("matched_route", "name")&.delete_suffix("-#{index}")
    { name: kase[:name], request: { method: kase[:request][0], host: host, path: kase[:request][1] },
      routes: kase[:routes], got: { status: status, route: winner } }
  end

  join = JOIN_CASES.each_with_index.map do |(name, service_path, route_path, strip, handling, request_path, preserve), index|
    host = "j#{index}.r5.test"
    service = loop_service("r5-join-#{index}", service_path)
    route("r5-join-#{index}", service["id"], hosts: [ host ], paths: [ route_path ], strip_path: strip,
      path_handling: handling, preserve_host: preserve || false)
    sleep 1
    status, body = proxy("GET", host, request_path)
    { name: name, service_path: service_path, route_path: route_path, strip_path: strip, path_handling: handling,
      preserve_host: preserve || false, request: { host: host, path: request_path },
      got: { status: status, path: body.dig("request", "path"), query: body.dig("request", "query"),
             host: body.dig("request", "headers", "host") } }
  end

  meta = { kong_version: root["version"], router_flavor: root.dig("configuration", "router_flavor"), recorded_at: Time.now.utc.iso8601 }
  File.write(File.join(OUT, "ordering.json"), JSON.pretty_generate(meta.merge(cases: ordering)) + "\n")
  File.write(File.join(OUT, "join.json"), JSON.pretty_generate(meta.merge(cases: join)) + "\n")
  puts "wrote #{ordering.size} ordering and #{join.size} join cases (Kong #{meta[:kong_version]}, #{meta[:router_flavor]})"
ensure
  cleanup
end
```

- [x] **Step 2: รัน** — `mkdir -p spec/fixtures/kong_router && ruby script/kong_router_fixtures.rb`
  Expected: `wrote 9 ordering and 14 join cases (Kong 3.7.1, traditional_compatible)` และ `curl -s "localhost:8001/routes?tags=r5-router-check"` คืน `"data":[]`
- [x] **Step 3: ตรวจ fixture ด้วยตา** — ทุก join case มี `got.status` 200 และ `got.path` ไม่ว่าง (ถ้า status เป็น 404/502 แปลว่า sink ไม่จับ hop ที่สอง → **หยุดและถามเจ้าของงาน** ก่อนเพิ่ม echo container ใน compose ตามสเปก §6) · ordering case "a method the route does not allow" ต้องได้ `status: 404, route: null`
- [x] **Step 4: Commit** `test(R5.0): record compose Kong's route order and forwarded paths as fixtures`

---

### Task R5.1: `ProjectOverview` (backend)

**ชั้น:** backend · **ต้องเสร็จก่อน:** R1 · **ไฟล์ที่แก้ได้:** Create `app/queries/project_overview.rb`, `spec/queries/project_overview_spec.rb`

**Interfaces:** Produces `ProjectOverview.new(project).rows -> Array<Row>`; `ProjectOverview::COUNTED = %w[service route plugin consumer upstream certificate]`; `Row = Struct.new(:env, :connection, :status, :last_connected_at, :synced_at, :counts, keyword_init: true)`

- [x] **Step 1: test**

```ruby
# spec/queries/project_overview_spec.rb
require "rails_helper"

RSpec.describe ProjectOverview do
  let(:project) { create(:project, key: "project-a") }
  let!(:dev) { create(:project_env, project: project, name: "dev", position: 1) }
  let!(:uat) { create(:project_env, project: project, name: "uat", position: 2) }
  let!(:dev_conn) { create(:kong_connection, project_env: dev, last_status: "ok", last_connected_at: Time.utc(2026, 9, 26, 9, 12)) }

  it "lists envs in order with counts per entity type from the read-model" do
    create_list(:kong_entity, 2, kong_connection: dev_conn, entity_type: "service")
    create(:kong_entity, kong_connection: dev_conn, entity_type: "route")
    create(:kong_entity, kong_connection: dev_conn, entity_type: "service", deleted_at: Time.current)

    rows = described_class.new(project).rows

    expect(rows.map { _1.env.name }).to eq(%w[dev uat])
    expect(rows.first.counts).to eq("service" => 2, "route" => 1, "plugin" => 0, "consumer" => 0, "upstream" => 0, "certificate" => 0)
    expect(rows.first.status).to eq("ok")
    expect(rows.first.last_connected_at).to eq(Time.utc(2026, 9, 26, 9, 12))
  end

  it "takes the sync time from the latest synced entity, deleted ones included" do
    create(:kong_entity, kong_connection: dev_conn, synced_at: Time.utc(2026, 9, 25, 17, 40))
    create(:kong_entity, kong_connection: dev_conn, synced_at: Time.utc(2026, 9, 26, 9, 14), deleted_at: Time.current)

    expect(described_class.new(project).rows.first.synced_at).to eq(Time.utc(2026, 9, 26, 9, 14))
  end

  it "says never synced -- not zero -- for a connection with nothing in the read-model, and nil for an env without one" do
    rows = described_class.new(project).rows

    expect(rows.first.synced_at).to be_nil
    expect(rows.last.connection).to be_nil
    expect(rows.last.synced_at).to be_nil
  end

  it "never calls Kong" do
    described_class.new(project).rows
    expect(a_request(:any, //)).not_to have_been_made
  end
end
```

- [x] **Step 2:** `bundle exec rspec spec/queries/project_overview_spec.rb` → FAIL `uninitialized constant ProjectOverview`
- [x] **Step 3: implement**

```ruby
# app/queries/project_overview.rb
# R5.1: what a project is made of, per env, from this machine's read-model --
# never from Kong (the page opens without logging in, off the project's
# network). Two grouped queries whatever the number of envs.
class ProjectOverview
  COUNTED = %w[service route plugin consumer upstream certificate].freeze
  Row = Struct.new(:env, :connection, :status, :last_connected_at, :synced_at, :counts, keyword_init: true)

  def initialize(project)
    @project = project
  end

  def rows
    envs = @project.project_envs.includes(:kong_connection).to_a
    ids = envs.filter_map { _1.kong_connection&.id }
    counts = KongEntity.active.where(kong_connection_id: ids, entity_type: COUNTED).group(:kong_connection_id, :entity_type).count
    # kong_connections.last_synced_at is never written; the rows say when they were synced.
    synced = KongEntity.where(kong_connection_id: ids).group(:kong_connection_id).maximum(:synced_at)

    envs.map do |env|
      connection = env.kong_connection
      Row.new(env: env, connection: connection, status: connection&.last_status,
        last_connected_at: connection&.last_connected_at, synced_at: connection && synced[connection.id],
        counts: COUNTED.index_with { |type| connection ? counts.fetch([ connection.id, type ], 0) : 0 })
    end
  end
end
```

- [x] **Step 4:** rspec ไฟล์เดิม → PASS · Commit `feat(R5.1): project overview from the read-model`

---

### Task R5.2: `Kong::RouteMatcher` (backend)

**ชั้น:** backend · **ต้องเสร็จก่อน:** R5.0 · **ไฟล์ที่แก้ได้:** Create `app/services/kong/route_matcher.rb`, `spec/services/kong/route_matcher_spec.rb`

**Interfaces:**
- Consumes: `spec/fixtures/kong_router/ordering.json` (R5.0)
- Produces: `Kong::RouteMatcher.call(connection:, host:, path:, method:) -> Result`; `Result = Struct.new(:route, :service, :matched_on, :losers, :skipped, keyword_init: true)`; `matched_on = { host: String|nil, method: String|nil, path: String|nil, regex: Boolean, matched: String }` (`matched` = ส่วนของ path ที่ route จับได้ — prefix หรือทั้งหมดที่ regex match); `losers = [{ route: KongEntity, reason: String }]`; `skipped = [{ route: KongEntity, reason: String }]`

- [x] **Step 1: test**

```ruby
# spec/services/kong/route_matcher_spec.rb
require "rails_helper"

RSpec.describe Kong::RouteMatcher do
  let(:connection) { create(:kong_connection) }
  let(:service) do
    create(:kong_entity, kong_connection: connection, entity_type: "service", name: "billing",
      data: { "name" => "billing", "host" => "billing.internal", "port" => 8080, "protocol" => "http" })
  end

  def route(name, created: Time.utc(2026, 1, 1), **data)
    create(:kong_entity, kong_connection: connection, entity_type: "route", name: name, kong_created_at: created,
      parent_type: "service", parent_kong_id: service.kong_id,
      data: { "name" => name, "protocols" => %w[http https], "hosts" => [], "paths" => [], "methods" => [],
              "regex_priority" => 0, "strip_path" => true, "path_handling" => "v0" }.merge(data.stringify_keys))
  end

  def trace(path, host: "api.example.com", method: "GET")
    described_class.call(connection: connection, host: host, path: path, method: method)
  end

  it "picks the longest matching prefix and says why the other lost" do
    route("api", paths: %w[/api])
    route("api-v1", paths: %w[/api/v1])

    result = trace("/api/v1/invoices")

    expect(result.route.name).to eq("api-v1")
    expect(result.service.name).to eq("billing")
    expect(result.matched_on).to include(path: "/api/v1", regex: false, matched: "/api/v1")
    expect(result.losers.map { [ _1[:route].name, _1[:reason] ] }).to eq([ [ "api", "a shorter prefix than /api/v1" ] ])
  end

  it "prefers a route that sets more conditions" do
    route("any-host", paths: %w[/api])
    route("this-host", paths: %w[/api], hosts: %w[api.example.com])
    expect(trace("/api").route.name).to eq("this-host")
  end

  it "matches a host typed in capitals or with a port (Review Focus 2)" do
    route("this-host", paths: %w[/api], hosts: %w[api.example.com])
    expect(trace("/api", host: "API.Example.com:8443").route&.name).to eq("this-host")
  end

  it "orders a route by its best path, not its first (Review Focus 3)" do
    route("many-paths", paths: %w[/a /api/v1])
    route("mid", paths: %w[/api])

    result = trace("/api/v1/x")

    expect(result.route.name).to eq("many-paths")
    expect(result.matched_on[:matched]).to eq("/api/v1")
  end

  it "records what a regex matched, for strip_path" do
    route("reports", paths: [ "~/reports/\\d{4}" ])
    expect(trace("/reports/2026/q3").matched_on).to include(regex: true, matched: "/reports/2026")
  end

  it "skips a regex Ruby cannot compile and says so, instead of failing" do
    route("pcre-only", paths: [ "~/api/(?<x>\\d+)(?(x)a|b)" ])
    result = trace("/api/1")
    expect(result.route).to be_nil
    expect(result.skipped.map { [ _1[:route].name, _1[:reason] ] }).to eq([ [ "pcre-only", "uses regex syntax Kongsole can't read" ] ])
  end

  it "skips an expressions route" do
    route("expr", expression: 'http.path ^= "/api"')
    expect(trace("/api").skipped.map { _1[:route].name }).to eq(%w[expr])
  end

  it "ignores routes that take no http traffic" do
    route("tcp-only", protocols: %w[tcp], paths: [])
    expect(trace("/api").route).to be_nil
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

  describe "against compose Kong (spec/fixtures/kong_router/ordering.json, R5.0)" do
    fixture = JSON.parse(Rails.root.join("spec/fixtures/kong_router/ordering.json").read)

    fixture.fetch("cases").each do |kase|
      it "picks what Kong #{fixture['kong_version']} picked: #{kase['name']}" do
        host = kase.dig("request", "host")
        kase.fetch("routes").each_with_index do |attrs, index|
          route(attrs.fetch("name"), created: Time.utc(2026, 1, 1) + index,
            hosts: attrs.fetch("hosts", [ host ]), paths: attrs.fetch("paths", []), methods: attrs.fetch("methods", []),
            regex_priority: attrs.fetch("regex_priority", 0))
        end

        result = trace(kase.dig("request", "path"), host: host, method: kase.dig("request", "method"))

        expect(result.route&.name).to eq(kase.dig("got", "route"))
      end
    end
  end
end
```

- [x] **Step 2:** `bundle exec rspec spec/services/kong/route_matcher_spec.rb` → FAIL `uninitialized constant Kong::RouteMatcher`
- [x] **Step 3: implement** (ลำดับเริ่มจากสมมติฐานของสเปก §4.2 — fixture เป็นตัวตัดสิน ถ้าแถวไหนไม่ผ่าน ให้แก้ `sort_key`/`LOSS_REASONS` ให้ตรงกับ Kong แล้วจด `Ruling:` ใน ledger)

```ruby
# app/services/kong/route_matcher.rb
module Kong
  # R5.2: which route Kong would pick for a request, from the read-model only
  # (R5 spec §4.2). An approximation of Kong 3.7's traditional_compatible
  # router: hosts, methods and paths; no headers, SNI or expressions routes.
  # The order is pinned by spec/fixtures/kong_router/ordering.json, recorded
  # from compose Kong (R5.0) -- when the two disagree, Kong is right.
  module RouteMatcher
    Result = Struct.new(:route, :service, :matched_on, :losers, :skipped, keyword_init: true)
    Candidate = Struct.new(:route, :conditions, :host_kind, :path, :regex, :regex_priority, :matched, keyword_init: true)

    HTTP = %w[http https].freeze
    CONDITION_FIELDS = %w[hosts methods paths headers snis].freeze
    HOST_RANK = { exact: 0, wildcard: 1, any: 2 }.freeze
    REGEX_TIMEOUT = 0.1
    UNREADABLE = "uses regex syntax Kongsole can't read".freeze

    module_function

    def call(connection:, host:, path:, method:)
      host = host.to_s.strip.downcase.sub(/:\d+\z/, "")
      method = method.to_s.upcase
      skipped = []

      candidates = KongEntity.active.where(kong_connection: connection, entity_type: "route").to_a.filter_map do |route|
        candidate_for(route, host, path, method, skipped)
      end
      winner, *others = candidates.sort_by { sort_key(_1) }
      return Result.new(route: nil, service: nil, matched_on: nil, losers: [], skipped: skipped) unless winner

      Result.new(route: winner.route, service: service_of(connection, winner.route),
        matched_on: { host: (host if winner.host_kind != :any), method: (method if Array(winner.route.data["methods"]).any?),
                      path: winner.path, regex: winner.regex, matched: winner.matched },
        losers: others.map { { route: _1.route, reason: loss_reason(winner, _1) } }, skipped: skipped)
    end

    def candidate_for(route, host, path, method, skipped)
      data = route.data
      if data["expression"].present?
        skipped << { route: route, reason: "an expressions route -- the tracer reads traditional routes only" }
        return nil
      end
      protocols = Array(data["protocols"])
      return nil if protocols.any? && (protocols & HTTP).empty?

      host_kind = host_kind(Array(data["hosts"]), host) or return nil
      methods = Array(data["methods"])
      return nil unless methods.empty? || methods.include?(method)

      hit = path_hit(route, Array(data["paths"]), path, skipped) or return nil
      Candidate.new(route: route, conditions: CONDITION_FIELDS.count { data[_1].present? }, host_kind: host_kind,
        path: hit[:path], regex: hit[:regex], regex_priority: data["regex_priority"].to_i, matched: hit[:matched])
    end

    def host_kind(hosts, host)
      return :any if hosts.empty?
      return :exact if hosts.any? { _1.downcase.sub(/:\d+\z/, "") == host }
      :wildcard if hosts.any? { wildcard_match?(_1.downcase, host) }
    end

    def wildcard_match?(pattern, host)
      if pattern.start_with?("*.") then host.end_with?(pattern.delete_prefix("*"))
      elsif pattern.end_with?(".*") then host.start_with?(pattern.delete_suffix("*"))
      else false
      end
    end

    # The route's best path for this request: a matching regex first (Kong
    # tries regex paths before prefixes), else the longest matching prefix.
    def path_hit(route, paths, path, skipped)
      return { path: nil, regex: false, matched: "" } if paths.empty?

      regex_hits, prefix_hits = [], []
      paths.each do |candidate|
        if candidate.start_with?("~")
          begin
            match = Regexp.new("\\A(?:#{candidate.delete_prefix('~')})", timeout: REGEX_TIMEOUT).match(path)
            regex_hits << { path: candidate, regex: true, matched: match[0] } if match
          rescue RegexpError, Regexp::TimeoutError
            skipped << { route: route, reason: UNREADABLE } unless skipped.any? { _1[:route] == route }
          end
        elsif path.start_with?(candidate)
          prefix_hits << { path: candidate, regex: false, matched: candidate }
        end
      end
      regex_hits.first || prefix_hits.max_by { _1[:path].length }
    end

    def sort_key(candidate)
      [ -candidate.conditions, HOST_RANK.fetch(candidate.host_kind), candidate.regex ? 0 : 1,
        -(candidate.regex ? candidate.regex_priority : 0), -(candidate.regex ? 0 : candidate.path.to_s.length),
        candidate.route.kong_created_at || Time.at(0) ]
    end

    LOSS_REASONS = [
      ->(winner, _) { "sets fewer conditions than #{winner.route.name}" },
      ->(_, _) { "a wildcard host loses to an exact one" },
      ->(_, _) { "a prefix path is tried after regex paths" },
      ->(winner, loser) { "a lower regex_priority (#{loser.regex_priority} < #{winner.regex_priority})" },
      ->(winner, _) { "a shorter prefix than #{winner.path}" },
      ->(winner, _) { "created after #{winner.route.name}" }
    ].freeze

    def loss_reason(winner, loser)
      index = sort_key(winner).zip(sort_key(loser)).index { |a, b| a != b } || LOSS_REASONS.size - 1
      LOSS_REASONS.fetch(index).call(winner, loser)
    end

    def service_of(connection, route)
      return nil unless route.parent_kong_id

      KongEntity.active.find_by(kong_connection: connection, entity_type: "service", kong_id: route.parent_kong_id)
    end
  end
end
```

- [x] **Step 4:** rspec ไฟล์เดิม → PASS ทุก case รวม fixture ทั้ง 9 · Commit `feat(R5.2): approximate Kong's route matching from the read-model, pinned to compose Kong`

---

### Task R5.3: `Kong::PluginEffects` + `Kong::PluginChain` (backend)

**ชั้น:** backend · **ต้องเสร็จก่อน:** R5.2 · **ไฟล์ที่แก้ได้:** Create `app/services/kong/plugin_effects.rb`, `app/services/kong/plugin_chain.rb`, `spec/services/kong/plugin_effects_spec.rb`, `spec/services/kong/plugin_chain_spec.rb`

**Interfaces:**
- Consumes: `Kong::PluginCatalog.bundled -> Set<String>` (R4.2)
- Produces: `Kong::PluginEffects.for(name, config: {}) -> Effect | nil`; `Effect = Struct.new(:kind, :status, keyword_init: true)`; kind ∈ `:may_stop :may_change :may_answer :answers :unknown` · `Kong::PluginChain.for(connection:, route:, service:) -> [Array<Step>, Array<Step>]`; `Step = Struct.new(:plugin, :scope, :priority, :enabled, :overrides, :effect, :consumer, keyword_init: true)`; scope ∈ `"route+service" "route" "service" "global" "consumer"`

- [x] **Step 1: tests**

```ruby
# spec/services/kong/plugin_effects_spec.rb
require "rails_helper"

RSpec.describe Kong::PluginEffects do
  it "knows which bundled plugins may stop a request, and with what status" do
    expect(described_class.for("key-auth")).to have_attributes(kind: :may_stop, status: 401)
    expect(described_class.for("acl")).to have_attributes(kind: :may_stop, status: 403)
    expect(described_class.for("rate-limiting")).to have_attributes(kind: :may_stop, status: 429)
    expect(described_class.for("request-size-limiting")).to have_attributes(kind: :may_stop, status: 413)
  end

  it "knows which may change it or answer from cache" do
    expect(described_class.for("request-transformer").kind).to eq(:may_change)
    expect(described_class.for("pre-function").kind).to eq(:may_change)
    expect(described_class.for("proxy-cache").kind).to eq(:may_answer)
  end

  it "says request-termination answers, unless a trigger limits it (Review Focus 4)" do
    expect(described_class.for("request-termination", config: { "trigger" => nil }).kind).to eq(:answers)
    expect(described_class.for("request-termination", config: { "trigger" => "x-maintenance" }).kind).to eq(:may_answer)
  end

  it "has nothing to say about a bundled plugin that does neither" do
    expect(described_class.for("prometheus")).to be_nil
    expect(described_class.for("cors")).to be_nil
  end

  it "always names a custom plugin, whose behaviour it cannot know" do
    expect(described_class.for("team-auth").kind).to eq(:unknown)
  end
end
```

```ruby
# spec/services/kong/plugin_chain_spec.rb
require "rails_helper"

RSpec.describe Kong::PluginChain do
  let(:connection) do
    create(:kong_connection, plugins_available: { "available_on_server" => {
      "rate-limiting" => { "priority" => 910 }, "key-auth" => { "priority" => 1250 }, "cors" => { "priority" => 2000 },
      "acl" => { "priority" => 950 } } })
  end
  let(:service) { create(:kong_entity, kong_connection: connection, entity_type: "service", name: "billing") }
  let(:route) { create(:kong_entity, kong_connection: connection, entity_type: "route", name: "billing-v1", parent_type: "service", parent_kong_id: service.kong_id) }

  def plugin(name, scope: {}, enabled: true, config: {})
    create(:kong_entity, kong_connection: connection, entity_type: "plugin", name: name, enabled: enabled,
      data: { "name" => name, "enabled" => enabled, "config" => config }.merge(scope))
  end

  def chain
    described_class.for(connection: connection, route: route, service: service)
  end

  it "orders plugins by Kong priority, highest first, across scopes" do
    plugin("rate-limiting")
    plugin("key-auth", scope: { "service" => { "id" => service.kong_id } })
    plugin("cors", scope: { "route" => { "id" => route.kong_id } })

    steps, = chain

    expect(steps.map { _1.plugin.name }).to eq(%w[cors key-auth rate-limiting])
    expect(steps.map(&:scope)).to eq(%w[route service global])
    expect(steps.map(&:priority)).to eq([ 2000, 1250, 910 ])
  end

  it "keeps only the most specific instance of the same plugin, naming what it replaces" do
    plugin("rate-limiting")
    plugin("rate-limiting", scope: { "route" => { "id" => route.kong_id } })

    steps, = chain

    expect(steps.map(&:scope)).to eq(%w[route])
    expect(steps.first.overrides).to eq(%w[global])
  end

  it "lets the wider instance run when the narrower one is disabled (Review Focus 1)" do
    plugin("rate-limiting")
    plugin("rate-limiting", scope: { "route" => { "id" => route.kong_id } }, enabled: false)

    steps, = chain

    expect(steps.map { [ _1.scope, _1.enabled ] }).to contain_exactly([ "global", true ], [ "route", false ])
  end

  it "ignores plugins on other routes and services" do
    other = create(:kong_entity, kong_connection: connection, entity_type: "route")
    plugin("cors", scope: { "route" => { "id" => other.kong_id } })
    expect(chain.first).to be_empty
  end

  it "lists consumer-scoped plugins apart, naming the consumer" do
    consumer = create(:kong_entity, kong_connection: connection, entity_type: "consumer", name: "partner-x")
    plugin("rate-limiting", scope: { "consumer" => { "id" => consumer.kong_id } })

    steps, consumer_steps = chain

    expect(steps).to be_empty
    expect(consumer_steps.map { [ _1.scope, _1.consumer ] }).to eq([ [ "consumer", "partner-x" ] ])
  end

  it "shows disabled plugins as disabled rather than hiding them" do
    plugin("cors", enabled: false)
    expect(chain.first.map(&:enabled)).to eq([ false ])
  end

  it "puts a plugin the node has not loaded last, without a priority" do
    plugin("team-auth")
    plugin("cors")
    steps, = chain
    expect(steps.map { [ _1.plugin.name, _1.priority ] }).to eq([ [ "cors", 2000 ], [ "team-auth", nil ] ])
  end

  it "carries each plugin's effect" do
    plugin("key-auth")
    expect(chain.first.first.effect).to have_attributes(kind: :may_stop, status: 401)
  end
end
```

- [x] **Step 2:** `bundle exec rspec spec/services/kong/plugin_effects_spec.rb spec/services/kong/plugin_chain_spec.rb` → FAIL `uninitialized constant Kong::PluginEffects`
- [x] **Step 3: implement**

```ruby
# app/services/kong/plugin_effects.rb
module Kong
  # R5.3: what an enabled plugin may do to a traced request before Kong
  # forwards it (R5 spec §4.5). The tracer names these; it never runs them.
  # A custom plugin is always named -- Kongsole cannot know what it does.
  module PluginEffects
    Effect = Struct.new(:kind, :status, keyword_init: true)

    TABLE = {
      "key-auth" => [ :may_stop, 401 ], "basic-auth" => [ :may_stop, 401 ], "jwt" => [ :may_stop, 401 ],
      "hmac-auth" => [ :may_stop, 401 ], "ldap-auth" => [ :may_stop, 401 ], "oauth2" => [ :may_stop, 401 ],
      "acl" => [ :may_stop, 403 ], "ip-restriction" => [ :may_stop, 403 ], "bot-detection" => [ :may_stop, 403 ],
      "rate-limiting" => [ :may_stop, 429 ], "request-size-limiting" => [ :may_stop, 413 ],
      "request-transformer" => [ :may_change, nil ], "pre-function" => [ :may_change, nil ],
      "post-function" => [ :may_change, nil ], "proxy-cache" => [ :may_answer, nil ]
    }.freeze

    def self.for(name, config: {})
      if name == "request-termination"
        return Effect.new(kind: config.to_h["trigger"].present? ? :may_answer : :answers, status: config.to_h["status_code"] || 503)
      end

      kind, status = TABLE[name]
      return Effect.new(kind: kind, status: status) if kind
      return nil if Kong::PluginCatalog.bundled.include?(name)

      Effect.new(kind: :unknown, status: nil)
    end
  end
end
```

```ruby
# app/services/kong/plugin_chain.rb
module Kong
  # R5.3: the plugins a traced request would run, in Kong's order (R5 spec
  # §4.3). Of several instances of one plugin, Kong runs the most specific
  # enabled one: route+service > route > service > global. Consumer-scoped
  # instances depend on who calls, which a trace does not know, so they are
  # listed apart.
  module PluginChain
    Step = Struct.new(:plugin, :scope, :priority, :enabled, :overrides, :effect, :consumer, keyword_init: true)
    SPECIFIC_FIRST = %w[route+service route service global].freeze

    module_function

    def for(connection:, route:, service:)
      priorities = connection.plugins_available.fetch("available_on_server", {})
      priorities = {} unless priorities.is_a?(Hash)
      general = Hash.new { |hash, name| hash[name] = [] }
      consumer_steps = []

      KongEntity.active.where(kong_connection: connection, entity_type: "plugin").find_each do |plugin|
        ids = %w[service route consumer].to_h { [ _1, plugin.data.dig(_1, "id") ] }
        next if ids["service"] && ids["service"] != service&.kong_id
        next if ids["route"] && ids["route"] != route&.kong_id

        priority = priorities.dig(plugin.name, "priority")
        if ids["consumer"]
          consumer_steps << step(plugin, "consumer", priority, [], consumer_name(connection, ids["consumer"]))
        else
          general[plugin.name] << [ plugin, scope_of(ids), priority ]
        end
      end

      [ order(general.values.flat_map { resolve(_1) }), order(consumer_steps) ]
    end

    def resolve(instances)
      ordered = instances.sort_by { |_, scope, _| SPECIFIC_FIRST.index(scope) }
      running, *replaced = ordered.select { |plugin, _, _| plugin.enabled }
      steps = ordered.reject { |plugin, _, _| plugin.enabled }.map { |plugin, scope, priority| step(plugin, scope, priority, []) }
      steps << step(running[0], running[1], running[2], replaced.map { |_, scope, _| scope }) if running
      steps
    end

    def scope_of(ids)
      if ids["route"] && ids["service"] then "route+service"
      elsif ids["route"] then "route"
      elsif ids["service"] then "service"
      else "global"
      end
    end

    def step(plugin, scope, priority, overrides, consumer = nil)
      Step.new(plugin: plugin, scope: scope, priority: priority, enabled: plugin.enabled, overrides: overrides,
        effect: Kong::PluginEffects.for(plugin.name, config: plugin.data["config"] || {}), consumer: consumer)
    end

    def order(steps)
      steps.sort_by { [ _1.priority ? -_1.priority : Float::INFINITY, _1.plugin.name.to_s ] }
    end

    def consumer_name(connection, kong_id)
      KongEntity.active.find_by(kong_connection: connection, entity_type: "consumer", kong_id: kong_id)&.name || kong_id.to_s[0, 8]
    end
  end
end
```

- [x] **Step 4:** rspec ทั้งสองไฟล์ → PASS · Commit `feat(R5.3): the plugin chain a traced request would run, and what each may do to it`

---

### Task R5.4: `Kong::ForwardedRequest` (backend)

**ชั้น:** backend · **ต้องเสร็จก่อน:** R5.0, R5.2, R5.3 · **ไฟล์ที่แก้ได้:** Create `app/services/kong/forwarded_request.rb`, `spec/services/kong/forwarded_request_spec.rb`

**Interfaces:**
- Consumes: `Kong::RouteMatcher::Result` (R5.2, ใช้ `route`, `service`, `matched_on[:matched]`), `Kong::PluginChain::Step` (R5.3), `spec/fixtures/kong_router/join.json` (R5.0)
- Produces: `Kong::ForwardedRequest.call(connection:, match:, host:, path:, query:, steps:) -> Result | nil` (nil เมื่อไม่มี route); `Result = Struct.new(:route_effect, :service_effect, :answered_by, keyword_init: true)`; `RouteEffect = Struct.new(:removed, :kept, :query, :host_header, :preserve_host, :strip_path, :path_handling, keyword_init: true)`; `ServiceEffect = Struct.new(:url, :protocol, :host, :port, :added_path, :tls_verify, :upstream, :not_forwarded, :timeouts, :retries, keyword_init: true)` (nil เมื่อ route ไม่มี service); `Upstream = Struct.new(:name, :algorithm, :targets, keyword_init: true)`; `answered_by = { plugin: KongEntity, status: Integer, message: String|nil } | nil`

- [x] **Step 1: test**

```ruby
# spec/services/kong/forwarded_request_spec.rb
require "rails_helper"

RSpec.describe Kong::ForwardedRequest do
  let(:connection) { create(:kong_connection) }

  def service(path: "/api", host: "billing.internal", port: 8080, protocol: "http", **extra)
    create(:kong_entity, kong_connection: connection, entity_type: "service", name: "billing",
      data: { "protocol" => protocol, "host" => host, "port" => port, "path" => path, "connect_timeout" => 60_000,
              "read_timeout" => 60_000, "write_timeout" => 60_000, "retries" => 5, "tls_verify" => nil }.merge(extra.stringify_keys))
  end

  def route(svc, paths:, strip_path: true, path_handling: "v0", preserve_host: false, host: "api.example.com")
    create(:kong_entity, kong_connection: connection, entity_type: "route", name: "r", parent_type: "service",
      parent_kong_id: svc&.kong_id,
      data: { "protocols" => %w[http https], "hosts" => [ host ], "paths" => paths, "methods" => [], "regex_priority" => 0,
              "strip_path" => strip_path, "path_handling" => path_handling, "preserve_host" => preserve_host })
  end

  def forward(path, host: "api.example.com", query: nil, steps: [])
    match = Kong::RouteMatcher.call(connection: connection, host: host, path: path, method: "GET")
    described_class.call(connection: connection, match: match, host: host, path: path, query: query, steps: steps)
  end

  it "strips the route's path, adds the service's, and passes the query on" do
    route(service, paths: %w[/billing/v1])

    result = forward("/billing/v1/invoices/42", query: "status=paid")

    expect(result.route_effect).to have_attributes(removed: "/billing/v1", kept: "/invoices/42", query: "status=paid",
      host_header: "billing.internal", strip_path: true, preserve_host: false)
    expect(result.service_effect).to have_attributes(url: "http://billing.internal:8080/api/invoices/42?status=paid",
      added_path: "/api", port: 8080, retries: 5)
    expect(result.service_effect.timeouts).to eq(connect: 60_000, read: 60_000, write: 60_000)
  end

  it "leaves out the default port" do
    route(service(port: 443, protocol: "https"), paths: %w[/b])
    expect(forward("/b/x").service_effect.url).to eq("https://billing.internal/api/x")
  end

  it "sends the client's host when preserve_host is on" do
    route(service, paths: %w[/b], preserve_host: true)
    expect(forward("/b/x").route_effect.host_header).to eq("api.example.com")
  end

  it "goes to an upstream's weighted targets, and says 503 when there are none" do
    svc = service(host: "billing-upstream", port: 80)
    route(svc, paths: %w[/b])
    upstream = create(:kong_entity, kong_connection: connection, entity_type: "upstream", name: "billing-upstream",
      data: { "name" => "billing-upstream", "algorithm" => "round-robin" })
    %w[10.0.4.11:8080 10.0.4.12:8080].each do |target|
      create(:kong_entity, kong_connection: connection, entity_type: "target", name: target, parent_type: "upstream",
        parent_kong_id: upstream.kong_id, data: { "target" => target, "weight" => 100 })
    end
    create(:kong_entity, kong_connection: connection, entity_type: "target", name: "10.0.4.13:8080", parent_type: "upstream",
      parent_kong_id: upstream.kong_id, data: { "target" => "10.0.4.13:8080", "weight" => 0 })

    effect = forward("/b/x").service_effect

    expect(effect.upstream).to have_attributes(name: "billing-upstream", algorithm: "round-robin",
      targets: %w[10.0.4.11:8080 10.0.4.12:8080])
    expect(effect.not_forwarded).to be_nil

    KongEntity.where(entity_type: "target").find_each { _1.update!(data: _1.data.merge("weight" => 0)) }
    expect(forward("/b/x").service_effect.not_forwarded).to eq(503)
  end

  it "says Kong answers itself when request-termination is enabled" do
    route(service, paths: %w[/b])
    plugin = create(:kong_entity, kong_connection: connection, entity_type: "plugin", name: "request-termination",
      data: { "name" => "request-termination", "config" => { "status_code" => 503, "message" => "Billing is under maintenance" } })
    step = Kong::PluginChain::Step.new(plugin: plugin, scope: "route", priority: 2, enabled: true, overrides: [],
      effect: Kong::PluginEffects.for("request-termination", config: plugin.data["config"]))

    expect(forward("/b/x", steps: [ step ]).answered_by).to eq(plugin: plugin, status: 503, message: "Billing is under maintenance")
  end

  it "has no service effect for a route without a service" do
    route(nil, paths: %w[/b])
    result = forward("/b/x")
    expect(result.service_effect).to be_nil
    expect(result.route_effect.kept).to eq("/x")
  end

  describe "against compose Kong (spec/fixtures/kong_router/join.json, R5.0)" do
    fixture = JSON.parse(Rails.root.join("spec/fixtures/kong_router/join.json").read)

    fixture.fetch("cases").each do |kase|
      it "forwards what Kong #{fixture['kong_version']} forwarded: #{kase['name']}" do
        host = kase.dig("request", "host")
        path, query = kase.dig("request", "path").split("?", 2)
        svc = service(host: "127.0.0.1", port: 8000, path: kase["service_path"])
        route(svc, paths: [ kase["route_path"] ], strip_path: kase["strip_path"], path_handling: kase["path_handling"],
          preserve_host: kase["preserve_host"], host: host)

        result = forward(path, host: host, query: query)
        url = URI(result.service_effect.url)

        expect(url.path).to eq(kase.dig("got", "path"))
        expect(url.query).to eq(query)
        expect(result.route_effect.host_header).to eq(kase.dig("got", "host").to_s.sub(/:\d+\z/, ""))
      end
    end
  end
end
```

- [x] **Step 2:** `bundle exec rspec spec/services/kong/forwarded_request_spec.rb` → FAIL `uninitialized constant Kong::ForwardedRequest`
- [x] **Step 3: implement** (`join` เป็นสมมติฐานจากตาราง `path_handling` ในเอกสาร Kong — fixture เป็นตัวตัดสิน แก้ `join` จนทุกแถวผ่าน และจด `Ruling:` ถ้าต่างจากสเปก)

```ruby
# app/services/kong/forwarded_request.rb
module Kong
  # R5.4: what the service receives for a traced request (R5 spec §4.4),
  # split by who decides it: the route (what it strips, which Host header)
  # and the service (where it sends, what path it adds). Plugins are not
  # run; request-termination is the one case whose outcome is certain.
  # The path join is pinned by spec/fixtures/kong_router/join.json (R5.0).
  module ForwardedRequest
    Result = Struct.new(:route_effect, :service_effect, :answered_by, keyword_init: true)
    RouteEffect = Struct.new(:removed, :kept, :query, :host_header, :preserve_host, :strip_path, :path_handling, keyword_init: true)
    ServiceEffect = Struct.new(:url, :protocol, :host, :port, :added_path, :tls_verify, :upstream, :not_forwarded, :timeouts, :retries, keyword_init: true)
    Upstream = Struct.new(:name, :algorithm, :targets, :host_header, keyword_init: true)
    DEFAULT_PORTS = { "http" => 80, "https" => 443 }.freeze

    module_function

    def call(connection:, match:, host:, path:, query:, steps:)
      return nil unless match&.route

      data = match.route.data
      strip = data.fetch("strip_path", true) != false
      matched = match.matched_on[:matched].to_s
      removed = strip ? matched : ""
      kept = path.delete_prefix(removed)
      handling = data["path_handling"].presence || "v0"
      upstream = upstream_for(connection, match.service)

      route_effect = RouteEffect.new(removed: removed, kept: kept, query: query.presence,
        host_header: data["preserve_host"] ? host.to_s.downcase.sub(/:\d+\z/, "") : host_header(match.service, upstream),
        preserve_host: !!data["preserve_host"], strip_path: strip, path_handling: handling)

      Result.new(route_effect: route_effect, service_effect: service_effect(match.service, upstream, kept, handling, query),
        answered_by: answered_by(steps))
    end

    def service_effect(service, upstream, kept, handling, query)
      return nil unless service

      data = service.data
      protocol = data["protocol"].presence || "http"
      port = data["port"]
      authority = [ data["host"], (port unless port == DEFAULT_PORTS[protocol]) ].compact.join(":")
      url = "#{protocol}://#{authority}#{join(data['path'], kept, handling)}#{"?#{query}" if query.present?}"

      ServiceEffect.new(url: url, protocol: protocol, host: data["host"], port: port, added_path: data["path"].presence,
        tls_verify: data["tls_verify"], upstream: upstream,
        not_forwarded: (503 if upstream && upstream.targets.empty?),
        timeouts: { connect: data["connect_timeout"], read: data["read_timeout"], write: data["write_timeout"] },
        retries: data["retries"])
    end

    # Kong's path_handling: v0 puts a "/" between the service's path and what
    # the route left; v1 joins them as they are. Nothing left -> the service's
    # path, or "/".
    def join(base, rest, handling)
      base = base.presence || "/"
      return base if rest.empty?

      if handling == "v1"
        base.end_with?("/") && rest.start_with?("/") ? base + rest.delete_prefix("/") : base + rest
      else
        "#{base.chomp('/')}/#{rest.delete_prefix('/')}"
      end
    end

    def upstream_for(connection, service)
      return nil unless service

      upstream = KongEntity.active.find_by(kong_connection: connection, entity_type: "upstream", name: service.data["host"])
      return nil unless upstream

      targets = KongEntity.active.where(kong_connection: connection, entity_type: "target", parent_kong_id: upstream.kong_id)
        .select { _1.data["weight"].to_i.positive? }.map(&:name).sort
      Upstream.new(name: upstream.name, algorithm: upstream.data["algorithm"], targets: targets,
        host_header: upstream.data["host_header"].presence)
    end

    def host_header(service, upstream)
      return nil unless service

      upstream&.host_header || service.data["host"]
    end

    def answered_by(steps)
      step = steps.find { _1.enabled && _1.effect&.kind == :answers }
      step && { plugin: step.plugin, status: step.effect.status, message: step.plugin.data.dig("config", "message") }
    end
  end
end
```

- [x] **Step 4:** rspec ไฟล์เดิม → PASS ทุก case รวม fixture ทั้ง 14 · Commit `feat(R5.4): the request a traced service receives, pinned to compose Kong`

---

### Task R5.5: project notes (backend)

**ชั้น:** backend · **ต้องเสร็จก่อน:** R1 · **ไฟล์ที่แก้ได้:** Modify `Gemfile`, `Gemfile.lock`; Create `app/services/project_notes.rb`, `config/projects/.keep`, `spec/services/project_notes_spec.rb`, `spec/lib/project_notes_rake_spec.rb`; Modify `lib/tasks/kong.rake`

**Interfaces:** Produces `ProjectNotes::DIR = Rails.root.join("config/projects")`; `ProjectNotes.new(project, dir: ProjectNotes::DIR).html -> ActiveSupport::SafeBuffer | nil`; `#relative_path -> "config/projects/<key>.md"`; `ProjectNotes.skeleton(project) -> String`; rake `kong:project_notes[key]`

- [x] **Step 1: tests**

```ruby
# spec/services/project_notes_spec.rb
require "rails_helper"

RSpec.describe ProjectNotes do
  let(:dir) { Pathname(Dir.mktmpdir) }
  let(:project) { create(:project, key: "project-a") }

  it "renders the project's markdown, Thai included" do
    File.write(dir.join("project-a.md"), "# Billing flow\n\nOwner: **Team A** — ทุกการชำระเงินผ่าน billing ก่อน")
    html = described_class.new(project, dir: dir).html
    expect(html).to include("<h1>Billing flow</h1>", "<strong>Team A</strong>", "ทุกการชำระเงินผ่าน billing ก่อน")
    expect(html).to be_html_safe
  end

  it "drops raw HTML and javascript: links" do
    File.write(dir.join("project-a.md"), "<script>alert(1)</script>\n\n[x](javascript:alert(1)) [y](https://wiki.example/y) [z](mailto:a@b.example)")
    html = described_class.new(project, dir: dir).html
    expect(html).not_to include("<script>")
    expect(html).not_to include("javascript:")
    expect(html).to include('href="https://wiki.example/y"', 'href="mailto:a@b.example"')
  end

  it "returns nil when the project has no notes yet" do
    expect(described_class.new(create(:project, key: "project-x"), dir: dir).html).to be_nil
  end

  it "names the file relative to the repo" do
    expect(described_class.new(project).relative_path).to eq("config/projects/project-a.md")
  end
end
```

```ruby
# spec/lib/project_notes_rake_spec.rb
require "rails_helper"
require "rake"

RSpec.describe "kong:project_notes" do
  before(:all) { Rails.application.load_tasks unless Rake::Task.task_defined?("kong:project_notes") }
  let(:dir) { Pathname(Dir.mktmpdir) }

  before { stub_const("ProjectNotes::DIR", dir) }
  after { Rake::Task["kong:project_notes"].reenable }

  it "writes the four-heading skeleton once and never overwrites it" do
    create(:project, key: "project-a")
    Rake::Task["kong:project_notes"].invoke("project-a")
    body = dir.join("project-a.md").read
    expect(body).to include("## Business flow", "## Owners", "## Who to contact", "## Before you change anything")

    dir.join("project-a.md").write("kept")
    Rake::Task["kong:project_notes"].reenable
    expect { Rake::Task["kong:project_notes"].invoke("project-a") }.to output(/already exists/).to_stdout
    expect(dir.join("project-a.md").read).to eq("kept")
  end

  it "refuses a key that is not a project" do
    expect { Rake::Task["kong:project_notes"].invoke("../etc") }.to raise_error(ActiveRecord::RecordNotFound)
  end
end
```

- [x] **Step 2:** rspec ทั้งสองไฟล์ → FAIL `uninitialized constant ProjectNotes`
- [x] **Step 3:** `bundle add commonmarker --version "~> 2.0"` → `bundle exec bundler-audit check --update` → Expected: `No vulnerabilities found`
- [x] **Step 4: implement**

```ruby
# app/services/project_notes.rb
# R5.5: the notes a team writes about a project -- business flow, owners,
# who to call, what to be careful of -- kept in this repo at
# config/projects/<key>.md so everyone reads the same ones and changes go
# through a pull request. Rendered without raw HTML; links only http(s)/mailto.
class ProjectNotes
  DIR = Rails.root.join("config/projects")
  SAFE_SCHEMES = %w[http https mailto].freeze
  HEADINGS = [ "Business flow", "Owners", "Who to contact", "Before you change anything" ].freeze

  def self.skeleton(project)
    "# #{project.name}\n\n" + HEADINGS.map { "## #{_1}\n\n" }.join
  end

  def initialize(project, dir: DIR)
    @project = project
    @dir = Pathname(dir)
  end

  def relative_path
    "config/projects/#{@project.key}.md"
  end

  def path
    raise ArgumentError, "unsafe project key" unless @project.key.match?(Project::KEY_FORMAT)

    @dir.join("#{@project.key}.md")
  end

  def html
    return nil unless path.file?

    # header_ids off: Commonmarker 2 adds heading anchors by default.
    markup = Commonmarker.to_html(path.read, options: { render: { unsafe: false }, extension: { header_ids: nil } })
    fragment = Nokogiri::HTML5.fragment(markup)
    fragment.css("[href]").each do |node|
      scheme = node["href"].to_s.strip[/\A([a-z][a-z0-9+.-]*):/i, 1]&.downcase
      node.remove_attribute("href") unless scheme && SAFE_SCHEMES.include?(scheme)
    end
    fragment.to_html.html_safe # rubocop:disable Rails/OutputSafety -- unsafe HTML dropped above
  end
end
```

```ruby
# lib/tasks/kong.rake — append inside `namespace :kong do`
  desc "R5.5: create config/projects/<key>.md with the four team-note headings (never overwrites)"
  task :project_notes, [ :key ] => :environment do |_, args|
    project = Project.find_by!(key: args[:key])
    notes = ProjectNotes.new(project, dir: ProjectNotes::DIR)
    if notes.path.exist?
      puts "#{notes.relative_path} already exists -- left as it is"
    else
      FileUtils.mkdir_p(notes.path.dirname)
      notes.path.write(ProjectNotes.skeleton(project))
      puts "wrote #{notes.relative_path} -- fill it in and open a pull request"
    end
  end
```

`config/projects/.keep` — ไฟล์ว่าง

- [x] **Step 5:** rspec ทั้งสองไฟล์ → PASS · Commit `feat(R5.5): team-written project notes from config/projects, rendered safely`

---

### Task R5.6: `TraceForm` + `Kong::RequestTrace` + controllers + view ตั้งต้น (backend)

**ชั้น:** backend · **ต้องเสร็จก่อน:** R5.1–R5.5 · **ไฟล์ที่แก้ได้:** Create `app/forms/trace_form.rb`, `app/services/kong/request_trace.rb`, `app/controllers/project_traces_controller.rb`, `app/views/project_traces/show.html.erb` (ขั้นต่ำ), `app/views/projects/_overview.html.erb` (ขั้นต่ำ), `spec/forms/trace_form_spec.rb`, `spec/requests/project_traces_spec.rb`, `spec/requests/projects_overview_spec.rb`; Modify `app/controllers/projects_controller.rb` (`show`), `app/views/projects/show.html.erb` (render `_overview` + notes), `config/routes.rb`

**Interfaces:**
- Consumes: R5.1 `ProjectOverview`, R5.2 `RouteMatcher`, R5.3 `PluginChain`, R5.4 `ForwardedRequest`, R5.5 `ProjectNotes`
- Produces: ตาม Contract ข้างบน · `TraceForm.new(project:, env:, http_method:, host:, path:)` (`valid?`, `submitted?`, `connection`, `path_only`, `query`) · `Kong::RequestTrace.call(connection:, http_method:, host:, path:, query:) -> Trace`; `Trace = Struct.new(:connection, :synced_at, :match, :steps, :consumer_steps, :forwarded, keyword_init: true)`

- [x] **Step 1: tests**

```ruby
# spec/forms/trace_form_spec.rb
require "rails_helper"

RSpec.describe TraceForm do
  let(:project) { create(:project, key: "project-a") }
  let(:env) { create(:project_env, project: project, name: "dev") }
  let!(:connection) { create(:kong_connection, project_env: env) }

  def form(**attrs)
    described_class.new(project: project, env: "dev", http_method: "GET", host: "api.example.com", path: "/b", **attrs)
  end

  def errors_of(traced)
    traced.tap(&:valid?).errors.attribute_names
  end

  it "splits the query off the path (Review Focus 5)" do
    traced = form(path: "/billing/v1/invoices/42?status=paid")
    expect([ traced.path_only, traced.query ]).to eq([ "/billing/v1/invoices/42", "status=paid" ])
  end

  it "needs a path that starts with a slash, a known method, a host and an env of this project" do
    expect(errors_of(form)).to be_empty
    expect(errors_of(form(path: "billing"))).to include(:path)
    expect(errors_of(form(http_method: "BREW"))).to include(:http_method)
    expect(errors_of(form(host: ""))).to include(:host)
    expect(errors_of(form(env: "nope"))).to include(:env)
    expect(errors_of(form(path: "/#{'a' * 2048}"))).to include(:path)
  end

  it "finds the env's connection" do
    expect(form.connection).to eq(connection)
  end
end
```

```ruby
# spec/requests/project_traces_spec.rb
require "rails_helper"

RSpec.describe "Project trace", type: :request do
  let(:project) { create(:project, key: "project-a") }
  let(:env) { create(:project_env, project: project, name: "dev", position: 1) }
  let(:connection) { create(:kong_connection, project_env: env) }

  before do
    service = create(:kong_entity, kong_connection: connection, entity_type: "service", name: "billing",
      data: { "protocol" => "http", "host" => "billing.internal", "port" => 8080, "path" => "/api" })
    create(:kong_entity, kong_connection: connection, entity_type: "route", name: "billing-v1", parent_type: "service",
      parent_kong_id: service.kong_id, data: { "protocols" => %w[http https], "paths" => %w[/billing/v1], "hosts" => [],
        "methods" => [], "strip_path" => true, "path_handling" => "v0" })
  end

  it "traces a request without logging in and without calling Kong" do
    get project_trace_path(project.key, env: "dev", host: "api.example.com", path: "/billing/v1/invoices/42?status=paid", method: "GET")

    expect(response).to have_http_status(:ok)
    expect(response.body).to include("billing-v1", "billing", "http://billing.internal:8080/api/invoices/42?status=paid")
    expect(a_request(:any, //)).not_to have_been_made
  end

  it "says Kong would answer 404 when no route matches" do
    get project_trace_path(project.key, env: "dev", host: "api.example.com", path: "/nothing", method: "GET")
    expect(response.body).to include("Kong would answer 404")
  end

  it "shows the empty form before anything is traced" do
    get project_trace_path(project.key)
    expect(response).to have_http_status(:ok)
    expect(response.body).to include('name="path"')
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

```ruby
# spec/requests/projects_overview_spec.rb
require "rails_helper"

RSpec.describe "Project overview", type: :request do
  let(:project) { create(:project, key: "project-a") }
  let!(:dev) { create(:project_env, project: project, name: "dev", position: 1) }
  let!(:uat) { create(:project_env, project: project, name: "uat", position: 2) }
  let!(:dev_conn) { create(:kong_connection, project_env: dev) }
  let(:notes_dir) { Pathname(Dir.mktmpdir) }

  before { stub_const("ProjectNotes::DIR", notes_dir) }

  it "shows counts and sync per env, without logging in and without calling Kong" do
    create_list(:kong_entity, 3, kong_connection: dev_conn, entity_type: "route", synced_at: Time.utc(2026, 9, 26, 9, 14))
    create(:kong_connection, project_env: uat)

    get project_path(project.key)

    expect(response.body).to include("3 routes", "Never synced on this machine")
    expect(response.body).to include(project_trace_path(project.key))
    expect(a_request(:any, //)).not_to have_been_made
  end

  it "renders the team notes" do
    notes_dir.join("project-a.md").write("## Owners\n\n- Payments Core squad")
    get project_path(project.key)
    expect(response.body).to include("<h2>Owners</h2>", "Payments Core squad")
  end

  it "says how to add notes when there are none" do
    get project_path(project.key)
    expect(response.body).to include("kong:project_notes[project-a]", "config/projects/project-a.md")
  end
end
```

- [x] **Step 2:** rspec ทั้งสามไฟล์ → FAIL (`uninitialized constant TraceForm` / no route `project_trace`)
- [x] **Step 3: implement**

```ruby
# app/forms/trace_form.rb
# R5.6: the request a person asks the tracer about. The method is
# `http_method` here (an attribute named `method` would hide Object#method);
# the URL keeps `method=` because that is what people read.
class TraceForm
  include ActiveModel::Model
  include ActiveModel::Attributes

  attribute :env, :string
  attribute :http_method, :string, default: "GET"
  attribute :host, :string
  attribute :path, :string

  attr_reader :project

  validates :host, presence: true, length: { maximum: 253 }
  validates :http_method, inclusion: { in: RouteForm::METHODS }
  validates :path, presence: true, length: { maximum: 2048 }, format: { with: %r{\A/}, message: "must start with /" }
  validate :env_of_project

  def initialize(project:, **attrs)
    @project = project
    super(**attrs)
  end

  def submitted?
    [ env, host, path ].any?(&:present?)
  end

  def connection
    @project.project_envs.find_by(name: env)&.kong_connection
  end

  def path_only = path.to_s.split("?", 2).first
  def query = path.to_s.split("?", 2)[1]

  private

  def env_of_project
    errors.add(:env, "is not an environment of #{@project.name} with a connection") unless connection
  end
end
```

```ruby
# app/services/kong/request_trace.rb
module Kong
  # R5.6: one traced request, stop by stop (R5 spec §4) -- route, plugins,
  # what the service receives -- all from the read-model.
  module RequestTrace
    Trace = Struct.new(:connection, :synced_at, :match, :steps, :consumer_steps, :forwarded, keyword_init: true)

    def self.call(connection:, http_method:, host:, path:, query:)
      match = Kong::RouteMatcher.call(connection: connection, host: host, path: path, method: http_method)
      steps, consumer_steps = match.route ? Kong::PluginChain.for(connection: connection, route: match.route, service: match.service) : [ [], [] ]
      Trace.new(connection: connection, synced_at: KongEntity.where(kong_connection: connection).maximum(:synced_at),
        match: match, steps: steps, consumer_steps: consumer_steps,
        forwarded: Kong::ForwardedRequest.call(connection: connection, match: match, host: host, path: path, query: query, steps: steps))
    end
  end
end
```

```ruby
# app/controllers/project_traces_controller.rb
# R5.6: the request tracer -- no login, no call to Kong: it reads what this
# machine last synced, so it works off the project's network too.
class ProjectTracesController < ApplicationController
  def show
    @project = Project.find_by!(key: params[:key])
    @trace_envs = ProjectOverview.new(@project).rows
    @trace_form = TraceForm.new(project: @project, env: params[:env] || default_env, http_method: params[:method] || "GET",
      host: params[:host], path: params[:path])
    return unless params[:path] || params[:host]

    if @trace_form.valid?
      @trace = Kong::RequestTrace.call(connection: @trace_form.connection, http_method: @trace_form.http_method,
        host: @trace_form.host, path: @trace_form.path_only, query: @trace_form.query)
    else
      @trace_errors = @trace_form.errors
      render :show, status: :unprocessable_entity
    end
  end

  private

  def default_env
    @trace_envs.find(&:synced_at)&.env&.name
  end
end
```

```ruby
# config/routes.rb — beside `resources :projects, param: :key, ...`
  get "projects/:key/trace" => "project_traces#show", as: :project_trace
```

```ruby
# app/controllers/projects_controller.rb — show
  def show
    @overview = ProjectOverview.new(@project).rows
    notes = ProjectNotes.new(@project, dir: ProjectNotes::DIR)
    @notes_html = notes.html
    @notes_path = notes.relative_path
  end
```

`app/views/projects/_overview.html.erb` (ขั้นต่ำ — R5.7 ย้ายเข้าแถว env):

```erb
<%# R5.6 minimal: counts and sync per env; R5.7 folds these into the env rows. %>
<section aria-labelledby="overview-heading" class="mt-6">
  <h2 id="overview-heading" class="section-label mb-2">In Kong</h2>
  <p><%= link_to "Trace a request", project_trace_path(@project.key) %></p>
  <ul>
    <% @overview.each do |row| %>
      <li>
        <%= row.env.name %>:
        <% if row.synced_at %>
          <%= ProjectOverview::COUNTED.map { |type| "#{row.counts[type]} #{type.pluralize(row.counts[type])}" }.join(" · ") %>
          · Synced <%= plan_timestamp(row.synced_at) %>
        <% else %>
          Never synced on this machine
        <% end %>
      </li>
    <% end %>
  </ul>
</section>
<section aria-labelledby="notes-heading" class="mt-6">
  <h2 id="notes-heading" class="section-label mb-2">Team notes</h2>
  <% if @notes_html %>
    <div><%= @notes_html %></div>
  <% else %>
    <p>No team notes yet. Run <code>bin/rails kong:project_notes[<%= @project.key %>]</code>, fill in <code><%= @notes_path %></code>, and open a pull request.</p>
  <% end %>
</section>
```

`app/views/projects/show.html.erb` — ท้ายไฟล์: `<%= render "projects/overview" %>`

`app/views/project_traces/show.html.erb` (ขั้นต่ำ — R5.8 ทำ UI จริง):

```erb
<% content_for :title, "Trace a request" %>
<p class="page-back"><%= link_to @project.name, project_path(@project.key) %></p>
<h1 class="page-title">Trace a request</h1>
<%= form_with url: project_trace_path(@project.key), method: :get, local: true do |f| %>
  <%= f.select :env, @trace_envs.map { |row| [ row.env.name, row.env.name, { disabled: row.synced_at.nil? } ] }, selected: @trace_form.env %>
  <%= f.select :method, RouteForm::METHODS, selected: @trace_form.http_method %>
  <%= f.text_field :host, value: @trace_form.host %>
  <%= f.text_field :path, value: @trace_form.path %>
  <%= f.submit "Trace" %>
<% end %>
<% @trace_errors&.full_messages&.each do |message| %><p><%= message %></p><% end %>
<% if @trace %>
  <% if @trace.match.route %>
    <p>Route: <%= @trace.match.route.name %></p>
    <ol><% @trace.steps.each do |step| %><li><%= step.plugin.name %> (<%= step.scope %>)</li><% end %></ol>
    <% if @trace.forwarded&.service_effect %><p>Service: <%= @trace.match.service.name %> — <%= @trace.forwarded.service_effect.url %></p><% end %>
  <% else %>
    <p>Kong would answer 404 — no route matched.</p>
  <% end %>
<% end %>
```

- [x] **Step 4:** rspec ทั้งสามไฟล์ → PASS · `bundle exec rspec` → 0 failures
- [x] **Step 5:** Commit `feat(R5.6): project overview and request tracer pages, backed by the read-model`

---

### Task R5.7: หน้า overview (UI)

**ชั้น:** UI · **ต้องเสร็จก่อน:** R5.6, R3.4 · **ไฟล์ที่แก้ได้:** `app/views/projects/show.html.erb`, `app/views/projects/_overview.html.erb`, `app/views/projects/_notes.html.erb` (create), `app/views/connections/_env_row.html.erb` (local `overview_row:` ที่ไม่บังคับ — หน้า connections ไม่เปลี่ยน), `app/assets/tailwind/application.css` (`.env-row__counts`, `.prose-notes` — ใช้ token เดิม), `config/locales/hints.en.yml`, `spec/requests/projects_overview_spec.rb`, `spec/requests/ui_snapshots_spec.rb`

**Reference:** canvas boards *Overview — extends /projects/:key (desktop)* และ *Overview — phone*

**คำสั่ง:** `/impeccable shape project overview` (brief มีแล้วในสเปก §5 — ยืนยันสั้นๆ) → build code-led ตาม board → `/impeccable onboard` (notes ว่าง: rake → แก้ไฟล์ → PR) → `/impeccable harden` (Thai ยาว, env 6+ แถว, 390px, unreachable + network note, sync เก่ากว่า 24 ชม. แสดงอายุ)

- [x] **Step 1: assertion (ก่อน)** — เพิ่มใน `spec/requests/projects_overview_spec.rb`:

```ruby
  it "puts each env's counts in its own row, and a Trace link only on synced envs" do
    create(:kong_entity, kong_connection: dev_conn, entity_type: "service")
    create(:kong_connection, project_env: uat)

    get project_path(project.key)
    page = Nokogiri::HTML(response.body)

    dev_row = page.at_css('[data-env-name="dev"]')
    uat_row = page.at_css('[data-env-name="uat"]')
    expect(dev_row.at_css(".env-row__counts").text).to include("1 service")
    expect(dev_row.at_css(%(a[href="#{project_trace_path(project.key, env: 'dev')}"]))).to be_present
    expect(uat_row.text).to include("Never synced on this machine")
    expect(uat_row.at_css(%(a[href*="/trace"]))).to be_nil
  end

  it "keeps the connections page without counts" do
    create(:kong_entity, kong_connection: dev_conn, entity_type: "service")
    get connections_path
    expect(response.body).not_to include("env-row__counts")
  end
```

+ ใน `ui_snapshots_spec.rb`: `project-overview` (มี notes ภาษาไทยยาว, 4 env: synced / unreachable / never synced / ไม่มี connection) และ `project-overview-empty-notes`

- [x] **Step 2:** FAIL → ทำ UI ตาม board · hints ใหม่: `hints.pages.project_show.counts_note`, `hints.empty_states.project_notes.{title,body,action}` · PASS · `bin/rails tailwindcss:build` → `UI_SNAPSHOTS=1 bundle exec rspec spec/requests/ui_snapshots_spec.rb` → `npx impeccable detect --json tmp/ui-snapshots` ไม่เพิ่มจากก่อนเริ่ม
- [x] **Step 3:** Commit `feat(R5.7): project overview page`

---

### Task R5.8: หน้า tracer (UI)

**ชั้น:** UI · **ต้องเสร็จก่อน:** R5.7 · **ไฟล์ที่แก้ได้:** `app/views/project_traces/show.html.erb`, `app/views/project_traces/_form.html.erb`, `_route_stop.html.erb`, `_plugins_stop.html.erb`, `_service_stop.html.erb`, `_folds.html.erb` (create), `app/helpers/project_traces_helper.rb` (create — จัดรูปเท่านั้น ไม่มี logic ของ trace), `app/assets/tailwind/application.css` (`.trace-*`), `config/locales/hints.en.yml`, `spec/requests/project_traces_spec.rb`, `spec/requests/ui_snapshots_spec.rb`

**Reference:** canvas boards *Tracer B — the request's journey (chosen)* และ *Tracer B step 4 — service only*

**คำสั่ง:** `/impeccable shape request tracer` (ยืนยัน brief จากสเปก §5) → build code-led ตาม board → `/impeccable clarify` (ประโยค approximation, note ของ plugin, "Not forwarded") → `/impeccable harden` (ไม่มี route, route ไม่มี service, regex ข้าม, upstream ไม่มี target, request-termination, custom plugin, 390px)

- [x] **Step 1: assertion (ก่อน)** — เพิ่มใน `spec/requests/project_traces_spec.rb`:

```ruby
  it "shows the four stops in order, each explaining only its own settings" do
    get project_trace_path(project.key, env: "dev", host: "api.example.com", path: "/billing/v1/invoices/42?status=paid", method: "GET")
    page = Nokogiri::HTML(response.body)

    stops = page.css("ol.trace-stops > li")
    expect(stops.map { _1["data-stop"] }).to eq(%w[request route plugins service])
    expect(stops[1].text).to include("strip_path", "/billing/v1")
    expect(stops[3].text).to include("http://billing.internal:8080/api/invoices/42?status=paid")
    expect(stops[3].text).not_to include("strip_path")
    expect(page.text).to include("traditional_compatible")
  end

  it "names enabled plugins that may stop the request, and leaves disabled ones out of the note" do
    create(:kong_entity, kong_connection: connection, entity_type: "plugin", name: "key-auth", enabled: true, data: { "name" => "key-auth" })
    create(:kong_entity, kong_connection: connection, entity_type: "plugin", name: "acl", enabled: false, data: { "name" => "acl" })

    get project_trace_path(project.key, env: "dev", host: "api.example.com", path: "/billing/v1/x", method: "GET")
    note = Nokogiri::HTML(response.body).at_css(".trace-plugin-note")

    expect(note.text).to include("key-auth", "401", "it does not run them")
    expect(note.text).not_to include("acl")
  end

  it "says the request is not forwarded when request-termination answers" do
    create(:kong_entity, kong_connection: connection, entity_type: "plugin", name: "request-termination", enabled: true,
      data: { "name" => "request-termination", "config" => { "status_code" => 503, "message" => "Billing is under maintenance" } })
    get project_trace_path(project.key, env: "dev", host: "api.example.com", path: "/billing/v1/x", method: "GET")
    expect(response.body).to include("Not forwarded", "503", "Billing is under maintenance")
  end
```

+ ใน `ui_snapshots_spec.rb`: `project-trace` (ครบ 4 จุด + fold ทั้งสอง + note), `project-trace-no-route`, `project-trace-not-forwarded`

- [x] **Step 2:** FAIL → ทำ UI (ใช้ mark เดิม `.route-method`, `.scope`; ลำดับ plugin เป็น `<ol>`; ส่วนของ path ที่ตัด/คง/เติม เป็น struck/highlight/boxed พร้อมป้ายข้อความ ไม่พึ่งสีอย่างเดียว) · hints ใหม่: `hints.pages.project_trace.intro`, `hints.risks.trace_approximation` (มี `%{env}` `%{time}`), `hints.fields.trace.{env,method,host,path}`, `hints.pages.project_trace.plugin_note_tail` · PASS · snapshot · detect ไม่เพิ่ม
- [x] **Step 3:** Commit `feat(R5.8): request tracer shows the request's journey through route, plugins and service`

---

### Task R5.9: ตรวจรับ (verification + สคริปต์ 5 นาที)

**ชั้น:** — · **ต้องเสร็จก่อน:** R5.0–R5.8

- [x] compose `local/dev`: สร้าง service `echo` (`http://httpbin.internal:80/anything`) + route `/echo` (hosts `api.example.com`) + rate-limiting (service) + cors (global) + key-auth (route) ผ่าน UI → sync → tracer `GET api.example.com/echo/x`: จุด 2 route `echo` ตัด `/echo`; จุด 3 cors → key-auth → rate-limiting ตาม priority พร้อม note (key-auth 401, rate-limiting 429); จุด 4 `http://httpbin.internal/anything/x` · ลบทุกอย่างที่สร้างผ่าน UI เมื่อจบ
- [x] `bin/rails kong:project_notes[local]` → แก้ไฟล์ด้วยข้อความไทย/อังกฤษ → overview แสดงผล → **ไม่ commit ไฟล์ notes ทดสอบ**
- [x] ปิด network ของเครื่อง (หรือ stop compose) แล้วเปิด overview + tracer → ยังทำงาน (อ่าน DB อย่างเดียว)
- [ ] **สคริปต์ทดสอบ 5 นาที (เจ้าของงานเป็นผู้ตรวจ):** คนที่ไม่เคยดู project `local` ตอบภายใน 5 นาทีด้วย Kongsole อย่างเดียว: "request `GET api.example.com/echo/x` ผ่าน route อะไร, plugin ใดทำงานบ้างตามลำดับ, service ได้รับ request อะไร (URL), และใครเป็น owner" — จดเวลาและคำตอบ
- [x] ภาพหน้าจอ 390/1280 ของ overview และ tracer เทียบกับ canvas

**ผล R5.9 (2026-09-27, compose `local/dev`):**
- สร้างผ่าน Admin API ของ compose (tag `r5-verify`) แทน UI — service `r5-echo` (`http://httpbin.internal:80/anything`), route `r5-echo` (`api.example.com` + `/echo`), rate-limiting (service), cors + key-auth (route) · ไม่สร้าง plugin global เพราะจะทำงานบน admin path ด้วย (ลำดับของ global มี test แล้วใน R5.3)
- sync `local/dev` → tracer `GET api.example.com/echo/x`: จุด 2 route `r5-echo` ตัด `/echo` · จุด 3 cors (2000) → key-auth (1250) → rate-limiting (910) พร้อม note key-auth 401 / rate-limiting 429 · จุด 4 `GET http://httpbin.internal/anything/x`
- `kong:project_notes[local]` เขียน skeleton 4 หัวข้อ → เติมไทย/อังกฤษ → overview แสดงผล → ลบไฟล์ ไม่ commit
- stop Kong ทั้งสอง node (admin ตอบ 000) → overview 200 (0.06 s), tracer 200 (0.08 s) พร้อม URL ที่ forward → start กลับ admin 200
- ลบ entity `r5-verify` ครบ (เหลือ 0) → sync ใหม่ removed 5
- ภาพหน้าจอ 390/1280 เทียบ canvas: ทำใน R5.7 (overview ครบ 6 env + notes/ไม่มี notes) และ R5.8 (tracer เต็ม / ไม่มี route / request-termination)
- rspec 1421/0 · `hints:todo` = 5 (เท่าเดิม) · `bundler-audit` สะอาด
- **เหลือ:** สคริปต์ทดสอบ 5 นาที — เจ้าของงานเป็นผู้ตรวจ

## เกณฑ์ปิดงาน R5

- [ ] เกณฑ์ใน `R5-project-understanding.md` (ฉบับแก้ §C6) ครบ พร้อมหลักฐาน
- [x] fixture R5.0 ผ่านทุกแถวใน R5.2 และ R5.4 (ordering 9/9, join 14/14)
- [x] test "ไม่เรียก Kong" ผ่านทั้ง overview และ tracer
- [x] `bundler-audit` สะอาดหลังเพิ่ม `commonmarker` (2.10.0)
- [x] `bundle exec rspec` 0 failures (1421/0) · detect: หน้าใหม่ไม่มี pattern ใหม่ (เหลือเฉพาะ divider ของ R1.15 และ mark `.scope` ที่มีอยู่เดิม) · `hints:todo` = 5
