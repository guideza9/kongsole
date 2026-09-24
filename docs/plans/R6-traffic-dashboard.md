# R6 — Traffic dashboard Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** dashboard ต่อ project/env/ช่วงเวลา แสดงจำนวน request ตามกลุ่ม status (2xx–5xx) และตาม status code, TPS และจำนวน request ทั้งแบบรวม ต่อ service และต่อ route โดย query Prometheus ขององค์กร (metric จาก Kong Prometheus plugin) — Kongsole ไม่เก็บ log หรือ metric เอง, มี preflight บอกว่า env ไหนยังไม่พร้อม, และบอกชัดเมื่อเครื่องนี้เข้า network ของ project นั้นไม่ได้

**Architecture:** `projects.prometheus_url` (จาก `connections.yml` หรือ UI ของ project local) + `project_envs.prometheus_selector` (label matcher ที่แยก Kong ของ env นั้น) → `Kong::PrometheusClient` (ไม่ส่ง credential — ตัดสินรอบ 2) → `Kong::TrafficQueries` (PromQL ที่สร้างอย่างปลอดภัย) → `DashboardsController` · หน้า dashboard render โครงทันทีโดยไม่เรียก Prometheus แล้วโหลดข้อมูลใน Turbo Frame แบบ lazy ต่อ env — Prometheus ของ project ที่อยู่คนละ network ล่มหรือเข้าไม่ถึงจึงไม่ทำให้หน้าค้าง · error เครือข่ายแยกชนิดด้วย `Kong::NetworkFailure` (R3.2) และแสดง `project.network_note` (R1)

**Tech Stack:** Prometheus HTTP API v1 (`/api/v1/query`, `/api/v1/query_range`), Faraday, Turbo Frames (lazy), server-rendered SVG (ไม่มี chart library ใหม่), RSpec + WebMock

**Spec:** `docs/requirements/R6-traffic-dashboard.md` (+ `design-amendments.md` §C7, §A4), `docs/plans/00-roadmap.md` (Q23, F4, รอบ 2 ข้อ 4–5)

## Global Constraints

- Kongsole ไม่เขียน metric/log ลงดิสก์หรือ DB (เก็บแค่ config: URL, selector)
- **ไม่ส่ง credential ให้ Prometheus** — ถ้าได้ 401/403 แสดงคำอธิบาย `prometheus_auth_required` และบันทึกเป็นงานต่อ (เพิ่ม credential เป็น task แยก ต้องหยุดถามเจ้าของงาน)
- `connections.yml` ห้ามมีค่าลับ: key ใดที่ชื่อมี `token|password|secret|credential` → loader ปฏิเสธทั้งไฟล์
- ค่าจาก read-model (ชื่อ service/route) ที่ใส่ใน PromQL ต้อง escape (`\` และ `"`) — ไม่มี string interpolation ดิบ
- `prometheus_selector` ต้อง match `/\A\{[a-zA-Z_][a-zA-Z0-9_]*(=|!=|=~|!~)"[^"\\]*(?:\\.[^"\\]*)*"(,\s*[a-zA-Z_][a-zA-Z0-9_]*(=|!=|=~|!~)"[^"\\]*(?:\\.[^"\\]*)*")*\}\z/`
- metric: `kong_http_requests_total{service, route, code, …}` — มีเฉพาะเมื่อ plugin เปิด `status_code_metrics: true` (default ของ Kong 3.7 คือ false — วัดแล้ว)
- timeout: เปิด connection 3s, รวม 10s ต่อ query; หน้า shell ไม่เรียก Prometheus เลย
- ไม่ต้อง login เพื่อดู dashboard (ตัดสินรอบ 2) — ไม่เรียก Kong
- ทดสอบกับ compose ในเครื่องเท่านั้น (R6.0 เพิ่ม Prometheus ใน compose); ห้ามชี้ไป Prometheus ขององค์กรระหว่างพัฒนา
- แก้ plugin prometheus (เปิด `status_code_metrics`) ใช้ R4 (direct) หรือ R8 (changeset) — dashboard ไม่มีปุ่มลัดเขียน Kong

## Review Focus

1. Prometheus ของ project อยู่คนละ network (DNS ไม่ resolve / timeout / refused / TLS) → frame ของ env นั้นบอกชนิดของปัญหา + `network_note` ของ project ภายใน ~10s ส่วนอื่นของหน้ายังใช้ได้ ไม่ 500 — test ใน R6.2 และ R6.5
2. Prometheus ตอบ 401/403 → คำอธิบาย "asks for credentials, Kongsole sends none yet" ไม่ใช่ "unreachable" — test ใน R6.2 และ R6.5
3. ชื่อ service มี `"` หรือ `\` → PromQL ยัง valid และไม่ถูก inject — test ใน R6.3
4. counter reset (Kong restart) ในช่วงเวลา → ใช้ `increase()` ไม่ใช่ลบค่าเอง — test ใน R6.3 (PromQL ที่ออกมา)
5. ช่วง 7 วัน → จำนวนจุด ≤ 300 (step คำนวณจากช่วง) — test ใน R6.3

---

## Spec ที่ตกลงแล้ว

- **เลือก:** project → env (ทุก env ที่มี selector) → ช่วงเวลา `1h | 6h | 24h | 7d` → มุมมอง `All | By service | By route` (+ filter service เมื่อดู route)
- **ตัวเลขหลัก:** total requests, average TPS, peak TPS (จาก series), สัดส่วน 5xx
- **กลุ่ม status:** 2xx/3xx/4xx/5xx (stacked over time) + ตาราง code → count
- **TPS series:** `sum(rate(kong_http_requests_total{SEL}[<window>]))` step = `max(range/300, 15s)`, window = `max(step, 1m)`
- **ต่อ service/route:** ตาราง name, total, 2xx, 4xx, 5xx, avg TPS เรียง total มากก่อน (top 50 + "N more")
- **Preflight ต่อ env:** (1) มี URL + selector, (2) Prometheus ตอบ (ถ้าไม่ตอบ บอกชนิด: dns / refused / timeout / tls / auth), (3) selector มี series (`count(kong_http_requests_total{SEL}) > 0`), (4) read-model มี plugin `prometheus` global หรือบางส่วน (บอก scope), (5) `config.status_code_metrics == true` — แต่ละข้อ ok/ไม่ ok พร้อมวิธีแก้
- **เครือข่ายของแต่ละ project:** ข้อความ error ใส่ `project.network_note` (เช่น "Reachable from the NONPROD VPN only") ถ้ามี; ถ้าไม่มี ใช้ข้อความทั่วไป "Check that this machine can reach <host> (VPN, proxy, firewall)"
- **ไม่ต้อง login**

## Contract UI ↔ backend

| backend ให้ | รายละเอียด |
|---|---|
| routes | `get "projects/:key/traffic" => "dashboards#show", as: :project_traffic` · `get "projects/:key/traffic/data" => "dashboards#data", as: :project_traffic_data` (Turbo Frame `traffic-data`) · `get "projects/:key/traffic/preflight" => "dashboards#preflight", as: :project_traffic_preflight` (Turbo Frame `traffic-preflight`) · `resource :prometheus_setting, path: "projects/:key/prometheus", only: %i[edit update]` |
| params | `env`, `range` (`1h`/`6h`/`24h`/`7d`, default `1h`), `view` (`all`/`service`/`route`), `service` (ชื่อ) — ค่าไม่รู้จัก → 422 |
| `show` | `@project`, `@envs` (มี selector), `@selected_env`, `@range`, `@view` — **ไม่เรียก Prometheus** |
| `data` | `@dashboard` = `TrafficDashboard(kpis: {total:, avg_tps:, peak_tps:, error_ratio:}, classes_series: {"2xx" => [[t, v]], …}, codes: {"200" => n}, tps_series: [[t, v]], rows: [{name:, total:, c2xx:, c4xx:, c5xx:, avg_tps:}], more_rows: Integer, range:, step:)` หรือ `@problem` = `Kong::ErrorExplanation::Result` (ตอบ 200 เสมอเพื่อให้ frame แสดงข้อความ) |
| `preflight` | `@preflight` = `Array<Kong::MetricsPreflight::Check(key:, ok:, detail:, fix_path:, explanation:)>` |
| settings | project local: `prometheus_url` แก้ได้; registry: อ่านอย่างเดียว · env local: `prometheus_selector` แก้ได้ |

---

### Task R6.0: Prometheus ใน compose (tooling)

**ชั้น:** backend (infra สำหรับทดสอบ) · **ต้องเสร็จก่อน:** R1 · **ไฟล์ที่แก้ได้:** `docker-compose.yml`, Create `docker/prometheus/prometheus.yml`, Modify `docker/kong/bootstrap.sh` (เพิ่ม plugin `prometheus` global บน dev ที่ `status_code_metrics: true`), `README.md` (หัวข้อ "Traffic dashboard locally")

- [ ] **Step 1:** เพิ่ม service `prometheus` (`prom/prometheus:v2.53.0`, port `9090`) scrape `kong-1:8001/metrics`, `kong-2:8001/metrics` ทุก 15s (Admin API ภายใน network — ไม่ผ่าน route ของ admin path)
- [ ] **Step 2:** `docker compose up -d prometheus` → `curl -s localhost:9090/api/v1/query --data-urlencode 'query=count(kong_http_requests_total)'` มีค่า หลังยิง request ผ่าน proxy
- [ ] **Step 3:** **spike:** บันทึก label จริงของ `kong_http_requests_total` บน Kong 3.7.1 (คาดว่า `service`, `route`, `code`, `source`, `workspace`, `consumer`) ลงใน commit message ถ้าไม่ตรงกับ contract ให้หยุดถาม
- [ ] **Step 4:** Commit `chore(R6.0): local Prometheus scraping the compose Kong nodes`

---

### Task R6.1: config ของ Prometheus (backend)

**ชั้น:** backend · **ต้องเสร็จก่อน:** R6.0 · **ไฟล์ที่แก้ได้:** Create `db/migrate/<ts>_add_prometheus_url_to_projects.rb`, `db/migrate/<ts>_add_prometheus_selector_to_project_envs.rb`; Modify `app/models/project.rb`, `app/models/project_env.rb`, `app/services/kong/connections_config_loader.rb`, `spec/models/project_spec.rb`, `spec/models/project_env_spec.rb`, `spec/services/kong/connections_config_loader_spec.rb`

- [ ] **Step 1: test**

```ruby
# spec/models/project_spec.rb — เพิ่ม
it "requires an http(s) Prometheus URL when one is set" do
  expect(build(:project, prometheus_url: "ftp://x")).not_to be_valid
  expect(build(:project, prometheus_url: nil)).to be_valid
  expect(build(:project, prometheus_url: "https://prom.example")).to be_valid
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
it "reads prometheus_url per project and prometheus_selector per env" do
  path = Rails.root.join("tmp/prom_registry.yml")
  File.write(path, { "projects" => [ { "key" => "p", "name" => "P", "prometheus_url" => "https://prom.test",
    "envs" => [ { "name" => "dev", "apply_mode" => "direct", "admin_url" => "http://localhost:8001",
      "prometheus_selector" => '{job="kong"}' } ] } ] }.to_yaml)
  described_class.call(path: path)
  expect(Project.find_by!(key: "p").prometheus_url).to eq("https://prom.test")
  expect(ProjectEnv.find_by!(name: "dev").prometheus_selector).to eq('{job="kong"}')
end

it "refuses the whole file when any key looks like a secret" do
  path = Rails.root.join("tmp/prom_registry_secret.yml")
  File.write(path, { "projects" => [ { "key" => "q", "name" => "Q", "prometheus_token" => "leak", "envs" => [] } ] }.to_yaml)
  expect { described_class.call(path: path) }.to raise_error(described_class::InvalidRegistry, /never in connections\.yml/)
  expect(Project.find_by(key: "q")).to be_nil
end
```

- [ ] **Step 2:** FAIL → migrations (`add_column :projects, :prometheus_url, :string`; `add_column :project_envs, :prometheus_selector, :string`) → validations → loader (secret-looking key check ทุกชั้น: `/(token|password|secret|credential)/i`) → PASS · migrate/rollback/migrate
- [ ] **Step 3:** Commit `feat(R6.1): Prometheus URL per project and selector per env`

---

### Task R6.2: `Kong::PrometheusClient` (backend)

**ชั้น:** backend · **ต้องเสร็จก่อน:** R6.1, R3.2 (`Kong::NetworkFailure`) · **ไฟล์ที่แก้ได้:** Create `app/services/kong/prometheus_client.rb`, `spec/services/kong/prometheus_client_spec.rb`

**Interfaces:** `Kong::PrometheusClient.new(project)`; `#query(promql, time: Time.current) -> Array<{metric: Hash, value: Float}>`; `#query_range(promql, start:, finish:, step:) -> Array<{metric: Hash, values: [[Time, Float]]}>`; errors (< `Kong::PrometheusClient::Error`): `Unreachable` (`#kind` ∈ `:dns, :refused, :timeout, :tls, :other` — จาก `Kong::NetworkFailure.classify(exception)`), `AuthRequired` (401/403), `BadQuery` (400/422), `Unavailable` (5xx); open_timeout 3s, timeout 10s; ไม่ใส่ header `Authorization`

- [ ] **Step 1: test**

```ruby
require "rails_helper"

RSpec.describe Kong::PrometheusClient do
  let(:project) { create(:project, prometheus_url: "https://prom.test") }

  it "queries without any credential and parses a vector" do
    stub_request(:get, "https://prom.test/api/v1/query").with(query: hash_including("query" => "up"))
      .to_return(status: 200, body: { status: "success", data: { resultType: "vector",
        result: [ { metric: { code: "200" }, value: [ 1_790_000_000, "42" ] } ] } }.to_json)
    expect(described_class.new(project).query("up")).to eq([ { metric: { "code" => "200" }, value: 42.0 } ])
    expect(a_request(:get, /prom\.test/).with { |req| req.headers.key?("Authorization") }).not_to have_been_made
  end

  it "says which network failure it was" do
    {
      Faraday::ConnectionFailed.new(SocketError.new("getaddrinfo: Name or service not known")) => :dns,
      Faraday::ConnectionFailed.new(Errno::ECONNREFUSED.new("connect(2)")) => :refused,
      Faraday::TimeoutError.new("execution expired") => :timeout,
      Faraday::SSLError.new("certificate verify failed") => :tls
    }.each do |error, kind|
      stub_request(:get, /prom\.test/).to_raise(error)
      expect { described_class.new(project).query("up") }
        .to raise_error(described_class::Unreachable) { |e| expect(e.kind).to eq(kind) }
    end
  end

  it "tells 'asks for credentials' apart from 'unreachable'" do
    [ 401, 403 ].each do |status|
      stub_request(:get, /prom\.test/).to_return(status: status, body: "{}")
      expect { described_class.new(project).query("up") }.to raise_error(described_class::AuthRequired)
    end
  end

  it "maps 400 to BadQuery with Prometheus's own error text" do
    stub_request(:get, /prom\.test/).to_return(status: 400, body: { status: "error", error: "parse error at char 3" }.to_json)
    expect { described_class.new(project).query("su(") }.to raise_error(described_class::BadQuery, /parse error/)
  end

  it "uses bounded timeouts" do
    connection = described_class.new(project).send(:faraday)
    expect(connection.options.open_timeout).to eq(3)
    expect(connection.options.timeout).to eq(10)
  end
end
```

- [ ] **Step 2:** FAIL → implement (Faraday ไม่มี logger middleware; ข้อความ error มีแค่ host ของ URL) → PASS · Commit `feat(R6.2): Prometheus client that names the network failure and never sends credentials`

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
    allow(client).to receive(:query).and_return([])
    allow(client).to receive(:query_range).and_return([])
    expect(client).to receive(:query).with('sum by (code) (increase(kong_http_requests_total{namespace="a-uat"}[3600s]))', time: anything)
      .and_return([ { metric: { "code" => "200" }, value: 900.0 }, { metric: { "code" => "503" }, value: 12.0 } ])
    dash = queries.dashboard(range: "1h", view: "all")
    expect(dash.codes).to eq("200" => 900, "503" => 12)
    expect(dash.kpis).to include(total: 912)
    expect(dash.kpis[:error_ratio]).to be_within(0.0001).of(12.0 / 912)
  end

  it "escapes read-model names before they enter PromQL" do
    expect(described_class.promql_escape('bad"name\\x')).to eq('bad\\"name\\\\x')
  end

  it "keeps a 7-day range to at most 300 points" do
    expect(7.days.to_i / described_class.step_for(7.days.to_i)).to be <= 300
  end

  it "filters routes to one service with an escaped matcher merged into the selector" do
    allow(client).to receive(:query).and_return([])
    allow(client).to receive(:query_range).and_return([])
    expect(client).to receive(:query).with(
      'sum by (route, code) (increase(kong_http_requests_total{namespace="a-uat",service="bil\\"ling"}[3600s]))', time: anything
    ).and_return([])
    queries.dashboard(range: "1h", view: "route", service: 'bil"ling')
  end

  it "reports zero traffic without dividing by zero" do
    allow(client).to receive(:query).and_return([])
    allow(client).to receive(:query_range).and_return([])
    expect(queries.dashboard(range: "1h", view: "all").kpis).to include(total: 0, error_ratio: 0.0)
  end
end
```

- [ ] **Step 2:** FAIL → implement (KPI: total = sum codes; avg_tps = total / range; peak จาก tps series; error_ratio = 5xx / total หรือ 0.0; ตาราง group by service/route แล้วรวม class ใน Ruby; error ของ client ส่งต่อขึ้นไปไม่กลืน) → PASS
- [ ] **Step 3:** Commit `feat(R6.3): PromQL for status classes, codes, TPS and per service/route`

---

### Task R6.4: preflight (backend)

**ชั้น:** backend · **ต้องเสร็จก่อน:** R6.3, R4.5 · **ไฟล์ที่แก้ได้:** Create `app/services/kong/metrics_preflight.rb`, `spec/services/kong/metrics_preflight_spec.rb`

**Interfaces:** `Kong::MetricsPreflight.for(project_env, client: Kong::PrometheusClient.new(project_env.project)) -> Array<Check>`; `Check = Struct.new(:key, :ok, :detail, :fix_path, :explanation, keyword_init: true)`; keys: `:configured, :reachable, :series, :plugin_present, :status_code_metrics`; `explanation` = `Kong::ErrorExplanation::Result` เมื่อ `:reachable` ไม่ผ่าน; `fix_path` ของ plugin = `edit_entity_path(plugin)` — เป็น path เท่านั้น ไม่มีการเขียน · ข้อ 4–5 อ่าน read-model จึงแสดงผลได้แม้ Prometheus เข้าไม่ถึง

- [ ] **Step 1: test**

```ruby
require "rails_helper"

RSpec.describe Kong::MetricsPreflight do
  let(:project) { create(:project, prometheus_url: "https://prom.test", network_note: "Reachable from the NONPROD VPN only") }
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

  it "explains an unreachable Prometheus with the project's network note, and still checks the read-model" do
    connection
    allow(client).to receive(:query).and_raise(Kong::PrometheusClient::Unreachable.new("timeout", kind: :timeout))
    checks = described_class.for(env, client: client).index_by(&:key)
    expect(checks[:reachable].ok).to be(false)
    expect(checks[:reachable].explanation.key).to eq("network_timed_out")
    expect(checks[:reachable].explanation.next_step).to include("NONPROD VPN")
    expect(checks[:series].ok).to be_nil # not checked, not "failed"
    expect(checks[:plugin_present]).not_to be_nil
  end

  it "explains a Prometheus that asks for credentials" do
    allow(client).to receive(:query).and_raise(Kong::PrometheusClient::AuthRequired, "401")
    expect(described_class.for(env, client: client).index_by(&:key)[:reachable].explanation.key).to eq("prometheus_auth_required")
  end
end
```

- [ ] **Step 2:** FAIL → implement → PASS · Commit `feat(R6.4): preflight names what is not ready and why, per env`

---

### Task R6.5: controllers + view ตั้งต้น (backend)

**ชั้น:** backend · **ต้องเสร็จก่อน:** R6.4 · **ไฟล์ที่แก้ได้:** Create `app/controllers/dashboards_controller.rb`, `app/controllers/prometheus_settings_controller.rb`, `app/views/dashboards/{show,data,preflight}.html.erb`, `app/views/prometheus_settings/edit.html.erb` (ขั้นต่ำ: turbo frame + ข้อมูลดิบ/ฟอร์ม), `spec/requests/dashboards_spec.rb`, `spec/requests/prometheus_settings_spec.rb`; Modify `config/routes.rb`, `config/locales/hints.en.yml` (key `hints.errors.prometheus_auth_required.*`, `hints.empty_states.traffic_not_configured.*` — ค่า `To Edit: pending` ให้ R6.7 เขียนจริง)

- [ ] **Step 1: test**

```ruby
# spec/requests/dashboards_spec.rb
require "rails_helper"

RSpec.describe "Traffic dashboard", type: :request do
  let(:project) { create(:project, key: "project-a", prometheus_url: "https://prom.test", network_note: "Reachable from the NONPROD VPN only") }
  let!(:env) { create(:project_env, project: project, name: "dev", position: 1, prometheus_selector: '{job="kong"}') }

  def ok_vector(value) = { status: "success", data: { resultType: "vector", result: [ { metric: { code: "200" }, value: [ 0, value ] } ] } }.to_json
  def ok_matrix = { status: "success", data: { resultType: "matrix", result: [] } }.to_json

  it "renders the page shell without calling Prometheus, and without a login" do
    get project_traffic_path(project.key, env: "dev", range: "1h")
    expect(response).to have_http_status(:ok)
    expect(response.body).to include('id="traffic-data"')
    expect(a_request(:any, /prom\.test/)).not_to have_been_made
  end

  it "fills the data frame with totals, classes and TPS" do
    stub_request(:get, %r{prom\.test/api/v1/query\?}).to_return(status: 200, body: ok_vector("100"))
    stub_request(:get, %r{prom\.test/api/v1/query_range}).to_return(status: 200, body: ok_matrix)
    get project_traffic_data_path(project.key, env: "dev", range: "1h")
    expect(response).to have_http_status(:ok)
    expect(response.body).to include("100")
  end

  it "answers the data frame with a network explanation instead of an error page" do
    stub_request(:get, /prom\.test/).to_raise(Faraday::ConnectionFailed.new(SocketError.new("getaddrinfo: Name or service not known")))
    get project_traffic_data_path(project.key, env: "dev", range: "1h")
    expect(response).to have_http_status(:ok)
    expect(response.body).to include(I18n.t("hints.errors.network_dns_failed.title"), "NONPROD VPN")
  end

  it "says Prometheus asks for credentials on 401" do
    stub_request(:get, /prom\.test/).to_return(status: 401, body: "{}")
    get project_traffic_data_path(project.key, env: "dev", range: "1h")
    expect(response.body).to include(I18n.t("hints.errors.prometheus_auth_required.title"))
  end

  it "explains missing configuration instead of querying" do
    env.update!(prometheus_selector: nil)
    get project_traffic_path(project.key, env: "dev")
    expect(response.body).to include(I18n.t("hints.empty_states.traffic_not_configured.title"))
    expect(a_request(:any, /prom\.test/)).not_to have_been_made
  end

  it "rejects an unknown range or env" do
    get project_traffic_data_path(project.key, env: "dev", range: "1y")
    expect(response).to have_http_status(:unprocessable_entity)
    get project_traffic_data_path(project.key, env: "nope")
    expect(response).to have_http_status(:not_found)
  end
end
```

```ruby
# spec/requests/prometheus_settings_spec.rb
require "rails_helper"

RSpec.describe "Prometheus settings", type: :request do
  it "lets a local project set its URL and a local env its selector" do
    project = create(:project, key: "project-a", source: "local")
    env = create(:project_env, project: project, name: "dev", source: "local")
    patch prometheus_setting_path(project.key), params: { prometheus_setting: { prometheus_url: "https://prom.test",
      selectors: { env.id.to_s => '{job="kong"}' } } }
    expect(project.reload.prometheus_url).to eq("https://prom.test")
    expect(env.reload.prometheus_selector).to eq('{job="kong"}')
  end

  it "leaves a registry project's settings to connections.yml" do
    registry = create(:project, key: "project-b", source: "registry", prometheus_url: "https://prom-b.test")
    patch prometheus_setting_path(registry.key), params: { prometheus_setting: { prometheus_url: "https://evil.test" } }
    expect(response).to have_http_status(:forbidden)
    expect(registry.reload.prometheus_url).to eq("https://prom-b.test")
  end

  it "re-renders with the selector error for a malformed selector" do
    project = create(:project, key: "project-c", source: "local")
    env = create(:project_env, project: project, name: "dev", source: "local")
    patch prometheus_setting_path(project.key), params: { prometheus_setting: { selectors: { env.id.to_s => "job=kong" } } }
    expect(response).to have_http_status(:unprocessable_entity)
    expect(env.reload.prometheus_selector).to be_nil
  end
end
```

- [ ] **Step 2:** FAIL → implement (`data`/`preflight` rescue `Kong::PrometheusClient::Error` → `@problem = Kong::ErrorExplanation.for(e, network_note: @project.network_note)`) → PASS · suite 0 failures
- [ ] **Step 3:** Commit `feat(R6.5): traffic dashboard loads per env and explains network problems in place`

---

### Task R6.6: dashboard (UI)

**ชั้น:** UI · **ต้องเสร็จก่อน:** R6.5, R3.4 · **ไฟล์ที่แก้ได้:** `app/views/dashboards/*`, `app/views/dashboards/_chart.html.erb` (create — SVG ฝั่ง server), `app/helpers/dashboards_helper.rb` (create — scale/path ของ SVG), `app/views/projects/show.html.erb` (ลิงก์ "Traffic"), `app/assets/tailwind/application.css` (สี series ใช้ tone เดิม success/warning/danger/neutral สำหรับ 2xx/3xx/4xx/5xx ตามความหมาย ไม่เพิ่ม hex), `config/locales/hints.en.yml` (`hints.pages.traffic.intro`, `hints.fields.traffic.*`, `hints.empty_states.traffic_*`), `spec/helpers/dashboards_helper_spec.rb` (create), `spec/requests/ui_snapshots_spec.rb`

**คำสั่ง:** โหลด skill `dataviz` ก่อน → `/impeccable shape traffic dashboard` → `/impeccable harden` (ไม่มีข้อมูล, ค่าเดียว, ตัวเลขใหญ่มาก, frame ที่ error, 390px)

- [ ] **Step 1:** helper spec (ก่อน): `sparkline_path(points, width:, height:)` คืน path ที่ครอบค่า min/max และไม่หารศูนย์เมื่อทุกค่าเท่ากัน; `format_count(1_234_567) == "1.23M"`
- [ ] **Step 2:** FAIL → ทำ UI: frame แสดงสถานะ "Loading traffic for <env>…" ระหว่างโหลด (`aria-busy`), แถวตัวเลขหลัก 4 ตัว, chart กลุ่ม status (มีตารางค่าเดียวกันให้ screen reader — `<table>` ใน `.disclosure` "Show as table"), ตาราง code, TPS line, ตาราง service/route · error ใน frame ใช้ `shared/_error_explanation` (R3.4) พร้อมปุ่ม "Try again" (reload frame) · ตัวเลือก env/range/view เป็น `.tab-nav` ตาม "One dialect" · no-JS: ลิงก์ "Load traffic data" ไปที่ `project_traffic_data_path` แบบเต็มหน้า
- [ ] **Step 3:** PASS · snapshot (มีข้อมูล, ไม่มีข้อมูล, network error, auth required) · detect · ภาพ 390/1280
- [ ] **Step 4:** Commit `feat(R6.6): traffic dashboard with status classes, codes, TPS and per service/route`

---

### Task R6.7: preflight + settings (UI)

**ชั้น:** UI · **ต้องเสร็จก่อน:** R6.6 · **ไฟล์ที่แก้ได้:** `app/views/dashboards/preflight.html.erb`, `app/views/dashboards/_preflight_check.html.erb` (create), `app/views/prometheus_settings/edit.html.erb`, `app/assets/tailwind/application.css`, `config/locales/hints.en.yml` (`hints.fields.prometheus.*`, `hints.risks.status_code_metrics_off`, `hints.errors.prometheus_auth_required.*`, `hints.empty_states.traffic_not_configured.*`), `spec/requests/ui_snapshots_spec.rb`

**คำสั่ง:** `/impeccable clarify` → `/impeccable onboard` (ครั้งแรกที่ยังไม่ตั้งค่า)

- [ ] **Step 1:** assertion (ก่อน): preflight แสดง 5 ข้อเป็นคำ (`Ready` / `Needs attention` / `Not checked`) พร้อมลิงก์แก้; ข้อ reachable ที่ไม่ผ่านแสดงชนิดปัญหาและ network note; ข้อความ auth required บอกว่า "Kongsole doesn't send credentials to Prometheus yet — tell the Kongsole owner" ; selector มีตัวอย่าง `{namespace="project-a-uat"}`; registry แสดงค่าอ่านอย่างเดียวพร้อม "Edit this in config/connections.yml"
- [ ] **Step 2:** FAIL → ทำ UI · PASS · snapshot · detect · Commit `feat(R6.7): preflight checklist and Prometheus settings`

---

### Task R6.8: ตรวจ flow จริง (verification)

**ชั้น:** — · **ต้องเสร็จก่อน:** R6.0–R6.7

- [ ] project `local`: `prometheus_url: http://localhost:9090`, env `dev` selector `{job="kong"}` (ตาม `docker/prometheus/prometheus.yml`)
- [ ] ยิง traffic ผ่าน proxy (`for i in $(seq 200); do curl -s -o /dev/null localhost:8000/echo; done` + request ที่ 404) → dashboard 1h: 2xx และ 4xx ตรงกับจำนวนที่ยิง (±scrape interval), ตาราง route มี `echo`
- [ ] ปิด `status_code_metrics` ของ plugin บน dev (ผ่าน Kongsole) → preflight แจ้ง + ลิงก์ไปแก้; เปิดกลับ
- [ ] จำลอง network ของ project อื่น (ตั้ง URL ชั่วคราวใน project local ทดสอบ): `http://prom.nonexistent.invalid` → DNS; `http://localhost:9` → refused; `http://10.255.255.1:9090` → timeout ภายใน ~10s — แต่ละกรณี shell ของหน้าโหลดทันที, frame แสดงชนิดปัญหา + network note, ไม่มี 500 ใน `log/development.log`
- [ ] `docker compose stop prometheus` → refused; start กลับ → "Try again" ได้ข้อมูล
- [ ] ภาพหน้าจอ

## เกณฑ์ปิดงาน R6

- [ ] เกณฑ์ใน `R6-traffic-dashboard.md` (ฉบับแก้ §C7) ครบ พร้อมหลักฐาน
- [ ] migration 2 ตัว up/down ผ่าน
- [ ] ไม่มีการเขียน metric/log ลงดิสก์หรือ DB · ไม่มี header `Authorization` ใน request ไป Prometheus (spec)
- [ ] network error ทุกชนิดแสดงคำอธิบายในหน้า ไม่ใช่ 500
- [ ] `bundle exec rspec` 0 failures · detect ไม่เพิ่ม · `hints:todo` รายงาน
- [ ] ถ้าระหว่างใช้จริงเจอ 401/403 จาก Prometheus ขององค์กร → เปิดงานต่อ "Prometheus credential" (หยุดถามเจ้าของงาน)
