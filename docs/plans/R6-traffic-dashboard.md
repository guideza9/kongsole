# R6 — Traffic dashboard Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** dashboard ต่อ project/env/ช่วงเวลา แสดงจำนวน request ตามกลุ่ม status (2xx–5xx) และตาม status code, TPS และจำนวน request ทั้งแบบรวม ต่อ service และต่อ route โดย query Prometheus ขององค์กร (metric จาก Kong Prometheus plugin) — Kongsole ไม่เก็บ log หรือ metric เอง และมี preflight บอกว่า connection ไหนยังไม่พร้อม (`status_code_metrics` ปิดอยู่)

**Architecture:** `projects.prometheus_url` (จาก `connections.yml` หรือ UI ของ project local) + `projects.prometheus_token` (optional, เข้ารหัส, ใส่ใน UI ของเครื่องตัวเองเท่านั้น) + `project_envs.prometheus_selector` (label matcher ที่แยก Kong ของ env นั้น) → `Kong::PrometheusClient` → `Kong::TrafficQueries` (PromQL ที่สร้างอย่างปลอดภัย) → `DashboardsController` · preflight อ่าน read-model (plugin `prometheus`) + ping Prometheus

**Tech Stack:** Prometheus HTTP API v1 (`/api/v1/query`, `/api/v1/query_range`), Faraday, server-rendered SVG (ไม่มี chart library ใหม่), Stimulus, RSpec + WebMock

**Spec:** `docs/requirements/R6-traffic-dashboard.md` (+ `design-amendments.md` §C7, §A4), `docs/plans/00-roadmap.md` (Q23, F4)

## Global Constraints

- Kongsole ไม่เขียน metric/log ลงดิสก์หรือ DB (มีแค่ config: URL, selector, token)
- `prometheus_token` = credential: `encrypts`, ไม่คืนผ่าน API ใดๆ, ไม่อยู่ใน `inspect`/log, ไม่อยู่ใน `connections.yml`
- ค่าจาก read-model (ชื่อ service/route) ที่ใส่ใน PromQL ต้อง escape (`\` และ `"`) — ไม่มี string interpolation ดิบ
- `prometheus_selector` ต้อง match `/\A\{[a-zA-Z_][a-zA-Z0-9_]*(=|!=|=~|!~)"[^"\\]*(?:\\.[^"\\]*)*"(,\s*[a-zA-Z_][a-zA-Z0-9_]*(=|!=|=~|!~)"[^"\\]*(?:\\.[^"\\]*)*")*\}\z/`
- metric: `kong_http_requests_total{service, route, code, …}` — มีเฉพาะเมื่อ plugin เปิด `status_code_metrics: true` (default ของ Kong 3.7 คือ false — วัดแล้ว)
- ทดสอบกับ compose ในเครื่องเท่านั้น (R6.0 เพิ่ม Prometheus ใน compose); ห้ามชี้ไป Prometheus ขององค์กรระหว่างพัฒนา
- แก้ plugin prometheus (เปิด `status_code_metrics`) ใช้ R4 (direct) หรือ R8 (changeset) — dashboard ไม่มีปุ่มลัดเขียน Kong

## Review Focus

1. Prometheus ตอบช้า/ล่ม → หน้าแสดงข้อความ + preflight ไม่ใช่ 500 และไม่ค้างนานกว่า 10 วินาที — test ใน R6.2
2. ชื่อ service มี `"` หรือ `\` → PromQL ยัง valid และไม่ถูก inject — test ใน R6.3
3. counter reset (Kong restart) ในช่วงเวลา → ใช้ `increase()` ไม่ใช่ลบค่าเอง — ตรวจใน R6.3 (PromQL ที่ออกมา)
4. env ที่ไม่มี selector หรือ project ไม่มี URL → dashboard บอกวิธีตั้งค่า ไม่ query — test ใน R6.5
5. ช่วง 7 วันที่ step เล็กเกิน → จำกัดจำนวนจุด ≤ 300 (step คำนวณจากช่วง) — test ใน R6.3

---

## Spec ที่ตกลงแล้ว

- **เลือก:** project → env (ทุก env ที่มี selector) → ช่วงเวลา `1h | 6h | 24h | 7d` → มุมมอง `All | By service | By route` (+ filter service เมื่อดู route)
- **ตัวเลขหลัก:** total requests, average TPS, peak TPS (จาก series), สัดส่วน 5xx
- **กลุ่ม status:** 2xx/3xx/4xx/5xx (stacked over time) + ตาราง code → count
- **TPS series:** `sum(rate(kong_http_requests_total{SEL}[<window>]))` step = `max(range/300, 15s)`, window = `max(step, 1m)`
- **ต่อ service/route:** ตาราง name, total, 2xx, 4xx, 5xx, avg TPS เรียง total มากก่อน (top 50 + "N more")
- **Preflight ต่อ env:** (1) มี URL + selector, (2) Prometheus ตอบ, (3) selector มี series (`count(kong_http_requests_total{SEL}) > 0`), (4) read-model มี plugin `prometheus` global หรือบางส่วน (บอก scope), (5) `config.status_code_metrics == true` — แต่ละข้อ ok/ไม่ ok พร้อมวิธีแก้ (ลิงก์ไปแก้ plugin)
- **ไม่ต้อง login** เพื่อดู dashboard (อ่าน Prometheus + DB ในเครื่อง) — ตัดสินเดียวกับ R5, ให้เจ้าของงานยืนยันตอนอนุมัติ

## Contract UI ↔ backend

| backend ให้ | รายละเอียด |
|---|---|
| routes | `get "projects/:key/traffic" => "dashboards#show", as: :project_traffic` · `resource :prometheus_setting, path: "projects/:key/prometheus", only: %i[edit update destroy]` |
| params | `env`, `range` (`1h`/`6h`/`24h`/`7d`, default `1h`), `view` (`all`/`service`/`route`), `service` (ชื่อ) |
| `@dashboard` | `TrafficDashboard(kpis: {total:, avg_tps:, peak_tps:, error_ratio:}, classes_series: {"2xx" => [[t, v]], …}, codes: {"200" => n}, tps_series: [[t, v]], rows: [{name:, total:, c2xx:, c4xx:, c5xx:, avg_tps:}], more_rows: Integer, range:, step:)` หรือ nil |
| `@preflight` | `Array<Kong::MetricsPreflight::Check(key:, ok:, detail:, fix_path:)>` |
| `@dashboard_error` | String (เช่น "Prometheus did not answer within 10s") |
| settings | form: `prometheus_url` (เฉพาะ project local; registry แสดงอ่านอย่างเดียว), `prometheus_token` (password, ไม่ prefill, "leave blank to keep", ปุ่ม "Forget token"), selector ต่อ env (เฉพาะ env local) |

---

### Task R6.0: Prometheus ใน compose (tooling)

**ชั้น:** backend (infra สำหรับทดสอบ) · **ต้องเสร็จก่อน:** R1 · **ไฟล์ที่แก้ได้:** `docker-compose.yml`, Create `docker/prometheus/prometheus.yml`, Modify `docker/kong/bootstrap.sh` (เพิ่ม plugin `prometheus` global บน dev ที่ `status_code_metrics: true`), `README.md` (หัวข้อ "Traffic dashboard locally")

- [ ] **Step 1:** เพิ่ม service `prometheus` (`prom/prometheus:v2.53.0`, port `9090`) scrape `kong-1:8001/metrics`, `kong-2:8001/metrics` ทุก 15s (Admin API ภายใน network — ไม่ผ่าน route ของ admin path)
- [ ] **Step 2:** `docker compose up -d prometheus` → `curl -s localhost:9090/api/v1/query --data-urlencode 'query=count(kong_http_requests_total)'` มีค่า หลังยิง request ผ่าน proxy
- [ ] **Step 3:** **spike:** บันทึก label จริงของ `kong_http_requests_total` บน Kong 3.7.1 (คาดว่า `service`, `route`, `code`, `source`, `workspace`, `consumer`) ลงใน commit message และปรับ R6.3 ถ้าไม่ตรง (หยุดถามถ้าต่างจาก contract)
- [ ] **Step 4:** Commit `chore(R6.0): local Prometheus scraping the compose Kong nodes`

---

### Task R6.1: config ของ Prometheus (backend)

**ชั้น:** backend · **ต้องเสร็จก่อน:** R6.0 · **ไฟล์ที่แก้ได้:** Create `db/migrate/<ts>_add_prometheus_to_projects.rb`, `db/migrate/<ts>_add_prometheus_selector_to_project_envs.rb`; Modify `app/models/project.rb`, `app/models/project_env.rb`, `app/services/kong/connections_config_loader.rb`, `spec/models/project_spec.rb`, `spec/models/project_env_spec.rb`, `spec/services/kong/connections_config_loader_spec.rb`, `spec/fixtures/connections/two_projects.yml`

- [ ] **Step 1: test**

```ruby
# spec/models/project_spec.rb — เพิ่ม
it "encrypts the Prometheus token and keeps it out of inspect and JSON" do
  project = create(:project, prometheus_token: "prom-secret")
  raw = ActiveRecord::Base.connection.select_value("SELECT prometheus_token FROM projects WHERE id = #{project.id}")
  expect(raw).not_to include("prom-secret")
  expect(project.inspect).not_to include("prom-secret")
  expect(project.as_json.to_s).not_to include("prom-secret")
end

it "requires an http(s) Prometheus URL" do
  expect(build(:project, prometheus_url: "ftp://x")).not_to be_valid
end
```

```ruby
# spec/models/project_env_spec.rb — เพิ่ม
it "accepts a label matcher selector and rejects anything else" do
  env = build(:project_env, prometheus_selector: '{namespace="project-a-uat", job="kong"}')
  expect(env).to be_valid
  env.prometheus_selector = '{namespace="x"}) or vector(1'
  expect(env).not_to be_valid
end
```

```ruby
# spec/services/kong/connections_config_loader_spec.rb — เพิ่ม
it "reads prometheus_url per project and prometheus_selector per env, and refuses a token in the file" do
  good = Rails.root.join("tmp/prom_registry.yml")
  File.write(good, { "projects" => [ { "key" => "p", "name" => "P", "prometheus_url" => "https://prom.test",
    "envs" => [ { "name" => "dev", "apply_mode" => "direct", "admin_url" => "http://localhost:8001",
      "prometheus_selector" => '{job="kong"}' } ] } ] }.to_yaml)
  described_class.call(path: good)
  expect(Project.find_by!(key: "p").prometheus_url).to eq("https://prom.test")
  expect(ProjectEnv.find_by!(name: "dev").prometheus_selector).to eq('{job="kong"}')

  bad = Rails.root.join("tmp/prom_registry_token.yml")
  File.write(bad, { "projects" => [ { "key" => "q", "name" => "Q", "prometheus_token" => "leak", "envs" => [] } ] }.to_yaml)
  expect { described_class.call(path: bad) }.to raise_error(described_class::InvalidRegistry, /never in connections\.yml/)
  expect(Project.find_by(key: "q")).to be_nil
end
```

- [ ] **Step 2:** FAIL → migrations (`add_column :projects, :prometheus_url, :string`; `add_column :projects, :prometheus_token, :text`; `add_column :project_envs, :prometheus_selector, :string`) → `encrypts :prometheus_token`; `inspect` filter แบบ `KongConnection` → PASS · migrate/rollback/migrate
- [ ] **Step 3:** Commit `feat(R6.1): Prometheus URL, selector and a locally encrypted token`

---

### Task R6.2: `Kong::PrometheusClient` (backend)

**ชั้น:** backend · **ต้องเสร็จก่อน:** R6.1 · **ไฟล์ที่แก้ได้:** Create `app/services/kong/prometheus_client.rb`, `spec/services/kong/prometheus_client_spec.rb`

**Interfaces:** `Kong::PrometheusClient.new(project)`; `#query(promql, time: Time.current) -> Array<{metric: Hash, value: Float}>`; `#query_range(promql, start:, finish:, step:) -> Array<{metric: Hash, values: [[Time, Float]]}>`; errors: `Unreachable`, `Unauthorized`, `BadQuery` (< `Kong::PrometheusClient::Error`); timeout 10s; Bearer header เมื่อมี token

- [ ] **Step 1: test**

```ruby
require "rails_helper"

RSpec.describe Kong::PrometheusClient do
  let(:project) { create(:project, prometheus_url: "https://prom.test", prometheus_token: "prom-secret") }

  it "queries with the bearer token and parses a vector" do
    stub_request(:get, "https://prom.test/api/v1/query").with(query: hash_including("query" => "up"),
      headers: { "Authorization" => "Bearer prom-secret" })
      .to_return(status: 200, body: { status: "success", data: { resultType: "vector",
        result: [ { metric: { code: "200" }, value: [ 1_790_000_000, "42" ] } ] } }.to_json)
    expect(described_class.new(project).query("up")).to eq([ { metric: { "code" => "200" }, value: 42.0 } ])
  end

  it "maps a timeout to Unreachable within the time limit" do
    stub_request(:get, /prom\.test/).to_timeout
    expect { described_class.new(project).query("up") }.to raise_error(described_class::Unreachable)
  end

  it "maps 400 to BadQuery with Prometheus's own error text" do
    stub_request(:get, /prom\.test/).to_return(status: 400, body: { status: "error", error: "parse error at char 3" }.to_json)
    expect { described_class.new(project).query("su(") }.to raise_error(described_class::BadQuery, /parse error/)
  end

  it "never logs the token" do
    io = StringIO.new
    Rails.logger.broadcast_to(Logger.new(io))
    stub_request(:get, /prom\.test/).to_return(status: 401, body: "{}")
    expect { described_class.new(project).query("up") }.to raise_error(described_class::Unauthorized)
    expect(io.string).not_to include("prom-secret")
  end
end
```

- [ ] **Step 2:** FAIL → implement (Faraday ไม่มี logger middleware; ข้อความ error ไม่มี header) → PASS · Commit `feat(R6.2): Prometheus HTTP API client with bounded timeouts`

---

### Task R6.3: `Kong::TrafficQueries` (backend)

**ชั้น:** backend · **ต้องเสร็จก่อน:** R6.2 · **ไฟล์ที่แก้ได้:** Create `app/services/kong/traffic_queries.rb`, `app/models/traffic_dashboard.rb` (PORO), `spec/services/kong/traffic_queries_spec.rb`

**Interfaces:** `Kong::TrafficQueries.new(client:, selector:)`; `#dashboard(range:, view:, service: nil, now: Time.current) -> TrafficDashboard`; `.promql_escape(value)`; `.step_for(range_seconds)`

- [ ] **Step 1: test**

```ruby
require "rails_helper"

RSpec.describe Kong::TrafficQueries do
  let(:client) { instance_double(Kong::PrometheusClient) }
  let(:queries) { described_class.new(client: client, selector: '{namespace="a-uat"}') }

  it "counts requests per code with increase() so counter resets are handled" do
    expect(client).to receive(:query).with('sum by (code) (increase(kong_http_requests_total{namespace="a-uat"}[3600s]))', time: anything)
      .and_return([ { metric: { "code" => "200" }, value: 900.0 }, { metric: { "code" => "503" }, value: 12.0 } ])
    allow(client).to receive(:query_range).and_return([])
    allow(client).to receive(:query).with(/by \(service\)|sum\(increase/, time: anything).and_return([])
    dash = queries.dashboard(range: "1h", view: "all")
    expect(dash.codes).to eq("200" => 900, "503" => 12)
  end

  it "escapes read-model names before they enter PromQL" do
    expect(described_class.promql_escape('bad"name\\x')).to eq('bad\\"name\\\\x')
  end

  it "keeps a 7-day range to at most 300 points" do
    expect(7.days.to_i / described_class.step_for(7.days.to_i)).to be <= 300
  end

  it "filters routes to one service with an escaped matcher merged into the selector" do
    expect(client).to receive(:query).with(
      'sum by (route, code) (increase(kong_http_requests_total{namespace="a-uat",service="bil\\"ling"}[3600s]))', time: anything
    ).and_return([])
    allow(client).to receive(:query).and_return([])
    allow(client).to receive(:query_range).and_return([])
    queries.dashboard(range: "1h", view: "route", service: 'bil"ling')
  end
end
```

- [ ] **Step 2:** FAIL → implement (KPI: total = sum codes; avg_tps = total / range; peak จาก tps series; error_ratio = 5xx / total; ตาราง group by service/route แล้วรวม class ใน Ruby) → PASS
- [ ] **Step 3:** Commit `feat(R6.3): PromQL for status classes, codes, TPS and per service/route`

---

### Task R6.4: preflight (backend)

**ชั้น:** backend · **ต้องเสร็จก่อน:** R6.3, R4.5 · **ไฟล์ที่แก้ได้:** Create `app/services/kong/metrics_preflight.rb`, `spec/services/kong/metrics_preflight_spec.rb`

**Interfaces:** `Kong::MetricsPreflight.for(project_env, client: Kong::PrometheusClient.new(project_env.project)) -> Array<Check>`; `Check = Struct.new(:key, :ok, :detail, :fix_path, keyword_init: true)`; keys: `:configured, :reachable, :series, :plugin_present, :status_code_metrics`; `fix_path` ของ plugin = `edit_entity_path(plugin)` (direct) หรือ `edit_entity_path` + changeset (pr) — เป็น path เท่านั้น ไม่มีการเขียน

- [ ] **Step 1: test**

```ruby
require "rails_helper"

RSpec.describe Kong::MetricsPreflight do
  let(:project) { create(:project, prometheus_url: "https://prom.test") }
  let(:env) { create(:project_env, project: project, prometheus_selector: '{job="kong"}') }
  let(:connection) { create(:kong_connection, project_env: env) }
  let(:client) { instance_double(Kong::PrometheusClient, query: [ { metric: {}, value: 3.0 } ]) }

  it "flags a prometheus plugin whose status_code_metrics is off, pointing at the plugin" do
    plugin = create(:kong_entity, kong_connection: connection, entity_type: "plugin", name: "prometheus",
      data: { "name" => "prometheus", "config" => { "status_code_metrics" => false } })
    checks = described_class.for(env, client: client).index_by(&:key)
    expect(checks[:plugin_present].ok).to be(true)
    expect(checks[:status_code_metrics]).to have_attributes(ok: false, fix_path: include(plugin.id.to_s))
  end

  it "says the plugin is missing when the read-model has none" do
    connection
    expect(described_class.for(env, client: client).index_by(&:key)[:plugin_present].ok).to be(false)
  end

  it "stops at configuration when the env has no selector, without querying" do
    env.update!(prometheus_selector: nil)
    expect(client).not_to receive(:query)
    expect(described_class.for(env, client: client).first).to have_attributes(key: :configured, ok: false)
  end

  it "reports Prometheus down as a failed check" do
    allow(client).to receive(:query).and_raise(Kong::PrometheusClient::Unreachable, "timeout")
    expect(described_class.for(env, client: client).index_by(&:key)[:reachable].ok).to be(false)
  end
end
```

- [ ] **Step 2:** FAIL → implement → PASS · Commit `feat(R6.4): preflight says which envs can feed the dashboard and how to fix the rest`

---

### Task R6.5: controllers + view ตั้งต้น (backend)

**ชั้น:** backend · **ต้องเสร็จก่อน:** R6.4 · **ไฟล์ที่แก้ได้:** Create `app/controllers/dashboards_controller.rb`, `app/controllers/prometheus_settings_controller.rb`, `app/views/dashboards/show.html.erb`, `app/views/prometheus_settings/edit.html.erb` (ขั้นต่ำ), `spec/requests/dashboards_spec.rb`, `spec/requests/prometheus_settings_spec.rb`; Modify `config/routes.rb`

- [ ] **Step 1: test**

```ruby
# spec/requests/dashboards_spec.rb
require "rails_helper"

RSpec.describe "Traffic dashboard", type: :request do
  let(:project) { create(:project, key: "project-a", prometheus_url: "https://prom.test") }
  let!(:env) { create(:project_env, project: project, name: "dev", position: 1, prometheus_selector: '{job="kong"}') }

  it "renders totals, classes and TPS from Prometheus" do
    stub_request(:get, %r{prom\.test/api/v1/query\?}).to_return(status: 200, body: { status: "success",
      data: { resultType: "vector", result: [ { metric: { code: "200" }, value: [ 0, "100" ] } ] } }.to_json)
    stub_request(:get, %r{prom\.test/api/v1/query_range}).to_return(status: 200, body: { status: "success",
      data: { resultType: "matrix", result: [] } }.to_json)
    get project_traffic_path(project.key, env: "dev", range: "1h")
    expect(response).to have_http_status(:ok)
    expect(response.body).to include("100")
  end

  it "explains missing configuration instead of querying" do
    env.update!(prometheus_selector: nil)
    get project_traffic_path(project.key, env: "dev")
    expect(response.body).to include(I18n.t("hints.empty_states.traffic_not_configured.title"))
    expect(a_request(:any, /prom\.test/)).not_to have_been_made
  end

  it "rejects an unknown range" do
    get project_traffic_path(project.key, env: "dev", range: "1y")
    expect(response).to have_http_status(:unprocessable_entity)
  end
end
```

```ruby
# spec/requests/prometheus_settings_spec.rb
require "rails_helper"

RSpec.describe "Prometheus settings", type: :request do
  let(:project) { create(:project, key: "project-a", source: "local", prometheus_url: "https://prom.test") }

  it "stores a token encrypted and never renders it back" do
    patch prometheus_setting_path(project.key), params: { prometheus_setting: { prometheus_token: "prom-secret" } }
    expect(project.reload.prometheus_token).to eq("prom-secret")
    get edit_prometheus_setting_path(project.key)
    expect(response.body).not_to include("prom-secret")
  end

  it "keeps the token on a blank submit and forgets it on delete" do
    project.update!(prometheus_token: "prom-secret")
    patch prometheus_setting_path(project.key), params: { prometheus_setting: { prometheus_token: "" } }
    expect(project.reload.prometheus_token).to eq("prom-secret")
    delete prometheus_setting_path(project.key)
    expect(project.reload.prometheus_token).to be_nil
  end

  it "leaves a registry project's URL to connections.yml but still takes a local token" do
    registry = create(:project, key: "project-b", source: "registry", prometheus_url: "https://prom-b.test")
    patch prometheus_setting_path(registry.key), params: { prometheus_setting: { prometheus_url: "https://evil.test" } }
    expect(response).to have_http_status(:forbidden)
    expect(registry.reload.prometheus_url).to eq("https://prom-b.test")

    patch prometheus_setting_path(registry.key), params: { prometheus_setting: { prometheus_token: "t" } }
    expect(registry.reload.prometheus_token).to eq("t")
  end
end
```

- [ ] **Step 2:** FAIL → implement → PASS · suite 0 failures · Commit `feat(R6.5): traffic dashboard and Prometheus settings pages`

---

### Task R6.6: dashboard (UI)

**ชั้น:** UI · **ต้องเสร็จก่อน:** R6.5, R3.4 · **ไฟล์ที่แก้ได้:** `app/views/dashboards/*`, `app/views/dashboards/_chart.html.erb` (create — SVG ฝั่ง server), `app/helpers/dashboards_helper.rb` (create — scale/path ของ SVG), `app/views/projects/show.html.erb` (ลิงก์ "Traffic"), `app/assets/tailwind/application.css` (token สี series: ใช้ tone เดิม success/warning/danger/neutral สำหรับ 2xx/3xx/4xx/5xx ตามความหมาย ไม่เพิ่ม hex), `config/locales/hints.en.yml` (`hints.pages.traffic.intro`, `hints.fields.traffic.*`, `hints.empty_states.traffic_*`), `spec/helpers/dashboards_helper_spec.rb` (create), `spec/requests/ui_snapshots_spec.rb`

**คำสั่ง:** โหลด skill `dataviz` ก่อน → `/impeccable shape traffic dashboard` → `/impeccable harden` (ไม่มีข้อมูล, ค่าเดียว, ตัวเลขใหญ่มาก, 390px)

- [ ] **Step 1:** helper spec (ก่อน): `sparkline_path(points, width:, height:)` คืน path ที่ครอบค่า min/max และไม่หารศูนย์เมื่อทุกค่าเท่ากัน; `format_count(1_234_567) == "1.23M"`
- [ ] **Step 2:** FAIL → ทำ UI: แถวตัวเลขหลัก 4 ตัว, chart กลุ่ม status (มีตารางค่าเดียวกันให้ screen reader — `<table>` ใน `.disclosure` "Show as table"), ตาราง code, TPS line, ตาราง service/route (ชื่อ route ใช้ mark `.route-match` ไม่ได้เพราะไม่มี path ใน metric → ชื่ออย่างเดียว) · ตัวเลือก env/range/view เป็น `.tab-nav` ตาม "One dialect"
- [ ] **Step 3:** PASS · snapshot (มีข้อมูล, ไม่มีข้อมูล, error) · detect · ภาพ 390/1280
- [ ] **Step 4:** Commit `feat(R6.6): traffic dashboard with status classes, codes, TPS and per service/route`

---

### Task R6.7: preflight + settings (UI)

**ชั้น:** UI · **ต้องเสร็จก่อน:** R6.6 · **ไฟล์ที่แก้ได้:** `app/views/dashboards/_preflight.html.erb` (create), `app/views/prometheus_settings/edit.html.erb`, `app/assets/tailwind/application.css`, `config/locales/hints.en.yml` (`hints.fields.prometheus.*`, `hints.risks.status_code_metrics_off`), `spec/requests/ui_snapshots_spec.rb`

**คำสั่ง:** `/impeccable clarify` → `/impeccable onboard` (ครั้งแรกที่ยังไม่ตั้งค่า)

- [ ] **Step 1:** assertion (ก่อน): preflight แสดง 5 ข้อเป็นคำ (`Ready` / `Needs attention`) พร้อมลิงก์แก้; ช่อง token เป็น password ไม่มี value; selector มีตัวอย่าง `{namespace="project-a-uat"}`
- [ ] **Step 2:** FAIL → ทำ UI · PASS · snapshot · detect · Commit `feat(R6.7): preflight checklist and Prometheus settings`

---

### Task R6.8: ตรวจ flow จริง (verification)

**ชั้น:** — · **ต้องเสร็จก่อน:** R6.0–R6.7

- [ ] project `local`: `prometheus_url: http://localhost:9090`, env `dev` selector `{job="kong"}` (ตาม `docker/prometheus/prometheus.yml`)
- [ ] ยิง traffic ผ่าน proxy (`for i in $(seq 200); do curl -s -o /dev/null localhost:8000/echo; done` + request ที่ 404) → dashboard 1h: 2xx และ 4xx ตรงกับจำนวนที่ยิง (±scrape interval), ตาราง route มี `echo`
- [ ] ปิด `status_code_metrics` ของ plugin บน dev (ผ่าน Kongsole) → preflight แจ้ง + ลิงก์ไปแก้; เปิดกลับ
- [ ] `docker compose stop prometheus` → หน้าแสดง error ภายใน 10s; start กลับ
- [ ] `grep -r "prom-secret" log/` ว่าง หลังตั้ง token ทดสอบ
- [ ] ภาพหน้าจอ

## เกณฑ์ปิดงาน R6

- [ ] เกณฑ์ใน `R6-traffic-dashboard.md` (ฉบับแก้ §C7) ครบ พร้อมหลักฐาน
- [ ] migration 2 ตัว up/down ผ่าน
- [ ] ไม่มีการเขียน metric/log ลงดิสก์หรือ DB (ตรวจ `git status` + ตารางใหม่ไม่มี)
- [ ] `bundle exec rspec` 0 failures · detect ไม่เพิ่ม · `hints:todo` รายงาน
- [ ] token ไม่หลุด (model spec + log grep)
