# R3 — Onboarding hints Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** มีที่เก็บ hint แหล่งเดียว (`config/locales/hints.en.yml`), ชิ้นส่วน UI ที่ใช้ซ้ำได้สำหรับคำอธิบาย field / empty state / คำเตือนผลกระทบ / error, การปิด hint แบบละเอียดที่คงอยู่หลัง reload และ retrofit หน้าที่มีอยู่แล้วทั้งหมด

**Architecture:** hint ทุกข้อความเป็น I18n key ใต้ `hints.*` · test env เปิด `raise_on_missing_translations` ทำให้ view ที่อ้าง key ที่ไม่มีล้ม test ทันที · การปิด hint = cookie `kongsole_hints` (`detailed` | `compact`) ที่ server อ่านได้ (ไม่มี flash) · error ของ `Kong::Client` ทั้ง 6 แบบแปลเป็น cause + next step ด้วย `Kong::ErrorExplanation` ตัวเดียว

**Tech Stack:** Rails I18n, Stimulus, Tailwind (tokens ใน `app/assets/tailwind/application.css`), RSpec request/helper specs

**Spec:** `docs/requirements/R3-onboarding-hints.md` (แก้ตาม `design-amendments.md` §C4), `docs/UI-DESIGN.md` (ภาษาภาพ + copy register), `docs/plans/00-roadmap.md`

## Global Constraints

- UI ภาษาอังกฤษทั้งหมด (Q15) · copy register ตาม `UI-DESIGN.md` §Copy register: label สั้นตรง, ประโยคที่สำคัญสุภาพและเจาะจง
- hint ที่ AI ไม่มั่นใจ ขึ้นต้นด้วย `To Edit: ` (มีช่องว่าง) — ห้ามลบ prefix เองจนกว่าเจ้าของงานแก้
- 13px เป็นขนาดต่ำสุด (`--text-xs`), ห้ามใส่ `style="…var(--color…)"` (มี spec บังคับ)
- ห้ามใส่ค่าลับหรือค่าจริงของ env ทีมใน example (ใช้ `example.internal`, `payments-api` ฯลฯ)
- ชั้น UI แก้ได้เฉพาะ `app/views/**`, `app/helpers/**` (presentational), `app/javascript/controllers/**`, `app/assets/tailwind/application.css`, `config/locales/hints.en.yml`

## Review Focus

1. ผู้ใช้กด "Hide detailed hints" แล้ว reload / เปิดหน้าอื่น → ยังซ่อนอยู่ ไม่กระพริบ — request spec ใน R3.1
2. key hint ที่ view อ้างแต่ไม่มีใน yml → test ล้ม (ไม่ใช่แสดง "translation missing") — config ใน R3.1 + spec ใน R3.4
3. เครื่องนี้ไม่ได้อยู่ใน network ของ project (DNS ไม่ resolve, refused, timeout, TLS) → บอกว่าเป็นปัญหาเครือข่ายพร้อมชนิด ไม่ใช่ "Admin API ล่ม" และ error อื่นที่ไม่ใช่ 6 แบบได้คำอธิบาย generic ไม่ใช่ 500 — spec ใน R3.2
4. cookie ถูกแก้เป็นค่าแปลก (`kongsole_hints=<script>`) → ตีความเป็น `detailed` — spec ใน R3.1
5. ข้อความ hint ยาว / tag ยาว / ชื่อ entity ภาษาไทย บนจอ 390px → ไม่ล้นแนวนอน — ตรวจใน R3.4 ด้วย snapshot 390x844

---

## Contract UI ↔ backend

| สิ่งที่ backend ให้ | ชนิด | ใช้ที่ |
|---|---|---|
| `detailed_hints?` (helper_method ใน `ApplicationController`) | `Boolean` — `true` เว้นแต่ cookie `kongsole_hints == "compact"` | partial hint, toggle |
| `PATCH /hint_preference` (`hint_preference_path`) param `mode=detailed\|compact` | redirect back (fallback `root_path`), set `cookies.permanent[:kongsole_hints]` httponly: false, same_site: :lax | toggle (form ปกติ ทำงานได้โดยไม่มี JS) |
| `Kong::ErrorExplanation.for(error, network_note: nil) -> Kong::ErrorExplanation::Result(key:, title:, cause:, next_step:)` | อ่าน `hints.errors.<key>.*`; ปัญหาเครือข่ายต่อท้าย `network_note` ของ project (R1.11) | controller rescue ทุกจุด + login + R6/R7/R8 |
| `Kong::Client::NetworkUnreachable#kind` | `:dns` / `:refused` / `:timeout` / `:tls` / `:other` (subclass ของ `UpstreamUnavailable`) | สถานะ + ข้อความ |
| `flash[:error_explanation]` = `{ "key", "title", "cause", "next_step" }` | Hash (string keys) | layout แสดงใต้ alert |
| `@schema_fields` ใน `entities#new/edit` | `Array<{name: String, type: String, required: Boolean, default: Object, one_of: Array, nested: Array}>` จาก `GET /schemas/<entity>` (nil ถ้าอ่านไม่ได้) | reference panel ของ type ที่ใช้ JSON editor |
| key ใน `hints.en.yml` | ตามโครงข้างล่าง | ทุก view |

โครง key (ห้ามเปลี่ยนชื่อชั้นบนสุดหลัง R3.1):

```yaml
en:
  hints:
    fields:            # hints.fields.<form>.<field>.{help,example}
      connection: { name: {help:, example:}, … }
      login: { … }
      service: { … }   # เติมโดย R2
      route: { … }     # เติมโดย R2
      upstream: { … }
      target: { … }
      certificate: { … }
      ca_certificate: { … }
      sni: { … }
      consumer: { … }
      plugin: { … }    # ส่วนกลางของ plugin (scope, enabled, tags) — config ของแต่ละ plugin อยู่ R4
    empty_states:      # hints.empty_states.<page>.{title,body,action}
    risks:             # hints.risks.<situation>.{title,body}
    errors:            # hints.errors.<key>.{title,cause,next_step}
    pages:             # hints.pages.<page>.intro — บรรทัดอธิบายใต้ h1
```

---

### Task R3.1: โครงสร้าง hint + การปิด hint (backend)

**ชั้น:** backend · **ต้องเสร็จก่อน:** T0 ทั้งหมด · **ไฟล์ที่แก้ได้:**
- Create: `config/locales/hints.en.yml` (โครง key + ค่า `To Edit: pending` ขั้นต่ำที่ spec ต้องใช้), `app/controllers/hint_preferences_controller.rb`, `lib/tasks/hints.rake`, `spec/requests/hint_preferences_spec.rb`, `spec/lib/hints_rake_spec.rb`
- Modify: `config/routes.rb`, `app/controllers/application_controller.rb`, `config/environments/test.rb` (`config.i18n.raise_on_missing_translations = true`)

**Interfaces:** Produces `detailed_hints?`, `hint_preference_path`, rake `hints:todo`

- [x] **Step 1: test การตั้งค่า**

```ruby
# spec/requests/hint_preferences_spec.rb
require "rails_helper"

RSpec.describe "Hint preference", type: :request do
  it "remembers compact hints across requests (a permanent cookie, read on the server)" do
    patch hint_preference_path, params: { mode: "compact" }, headers: { "HTTP_REFERER" => connections_url }
    expect(response).to redirect_to(connections_url)
    expect(cookies[:kongsole_hints]).to eq("compact")

    get connections_path
    expect(controller.send(:detailed_hints?)).to be(false)
  end

  it "treats anything but 'compact' as detailed" do
    cookies[:kongsole_hints] = "<script>"
    get connections_path
    expect(controller.send(:detailed_hints?)).to be(true)
  end

  it "rejects an unknown mode without touching the cookie" do
    patch hint_preference_path, params: { mode: "bogus" }
    expect(response).to have_http_status(:unprocessable_entity)
    expect(cookies[:kongsole_hints]).to be_nil
  end
end
```

- [x] **Step 2: test ของ rake `hints:todo`**

```ruby
# spec/lib/hints_rake_spec.rb
require "rails_helper"
require "rake"

RSpec.describe "hints:todo" do
  before(:all) { Rails.application.load_tasks }

  it "lists every hint still marked To Edit, by key" do
    I18n.backend.store_translations(:en, hints: { fields: { demo: { x: { help: "To Edit: check this" } } } })
    expect { Rake::Task["hints:todo"].execute }.to output(/hints\.fields\.demo\.x\.help/).to_stdout
  end
end
```

- [x] **Step 3:** รัน 2 ไฟล์ → FAIL
- [x] **Step 4: implement**

```ruby
# app/controllers/hint_preferences_controller.rb
# R3: the "hide detailed hints" switch. No user database (docs/DESIGN.md
# section 3), so the choice belongs to the browser, as a cookie the server
# reads -- the page renders in the chosen mode with no flash of hints.
class HintPreferencesController < ApplicationController
  MODES = %w[detailed compact].freeze

  def update
    mode = params[:mode].to_s
    return head(:unprocessable_entity) unless MODES.include?(mode)

    cookies.permanent[:kongsole_hints] = { value: mode, same_site: :lax }
    redirect_back fallback_location: root_path
  end
end
```

```ruby
# app/controllers/application_controller.rb — เพิ่ม
helper_method :detailed_hints?

def detailed_hints?
  cookies[:kongsole_hints] != "compact"
end
```

```ruby
# config/routes.rb
resource :hint_preference, only: :update
```

```ruby
# lib/tasks/hints.rake
namespace :hints do
  desc "List hints still marked 'To Edit:' for the owner to review (R3)"
  task todo: :environment do
    I18n.backend.send(:init_translations) unless I18n.backend.initialized?
    walk = lambda do |node, path|
      case node
      when Hash then node.each { |k, v| walk.call(v, [ *path, k ]) }
      when String then puts "#{path.join('.')}: #{node}" if node.start_with?("To Edit:")
      end
    end
    walk.call(I18n.backend.send(:translations).dig(:en, :hints) || {}, [ "hints" ])
  end
end
```

- [x] **Step 5:** PASS ทั้ง 2 ไฟล์ · รันทั้ง suite (เปิด `raise_on_missing_translations` แล้ว) → 0 failures (ถ้า view เดิมมี `t()` ที่หาย key ให้หยุดรายงาน)
- [x] **Step 6:** Commit `feat(R3.1): one hints file, a server-read hint preference, and hints:todo`

**เกณฑ์ผ่าน:** 3+1 examples ผ่าน · suite 0 failures

---

### Task R3.2: คำอธิบาย error ของ Kong 6 แบบ + ปัญหาเครือข่าย (backend)

**ชั้น:** backend · **ต้องเสร็จก่อน:** R3.1 · **ไฟล์ที่แก้ได้:**
- Create: `app/services/kong/network_failure.rb`, `app/services/kong/error_explanation.rb`, `spec/services/kong/network_failure_spec.rb`, `spec/services/kong/error_explanation_spec.rb`
- Modify: `app/services/kong/client.rb` (network failure → `NetworkUnreachable` แทน `UpstreamUnavailable` ตรงๆ), `spec/services/kong/client_spec.rb`, `app/controllers/sessions_controller.rb` (`login_error_message` → ใช้ ErrorExplanation), `app/controllers/entities_controller.rb`, `app/controllers/plugins_controller.rb` (rescue `Kong::Client::Error` ใส่ `flash[:error_explanation]`), `config/locales/hints.en.yml` (key `hints.errors.*` 12 ตัว — ค่าเป็น `To Edit: pending`, R3.5 เขียนจริง), `spec/requests/sessions_spec.rb`, `spec/requests/entities_spec.rb`

**ทำไม:** แต่ละ project อยู่คนละ network (ตัดสินรอบ 2 ข้อ 4) แต่ `Kong::Client#request` ตอนนี้แปลง DNS/refused/timeout/TLS ทั้งหมดเป็น `UpstreamUnavailable` ซึ่งเป็น class เดียวกับ 502/503 จาก loopback — ผู้ใช้ที่ไม่ได้ต่อ VPN ของ project จะเห็นว่า "Admin API ล่ม" ซึ่งผิด

**Interfaces:**
- Produces `Kong::NetworkFailure.classify(exception) -> Symbol` ∈ `:dns, :refused, :timeout, :tls, :other` (ดู `exception` และ `exception.cause` ไล่ลงไป: `SocketError`/`getaddrinfo`/`Name or service not known`/`nodename nor servname` → `:dns`; `Errno::ECONNREFUSED`/`Connection refused` → `:refused`; `Faraday::TimeoutError`/`Net::OpenTimeout`/`Net::ReadTimeout`/`execution expired` → `:timeout`; `Faraday::SSLError`/`OpenSSL::SSL::SSLError`/`certificate verify failed` → `:tls`)
- Produces `Kong::NetworkFailure.classify_text(text) -> Symbol | nil` สำหรับ stderr ของ decK/git: `no such host`/`Could not resolve host` → `:dns`; `connection refused` → `:refused`; `i/o timeout`/`timed out` → `:timeout`; `x509`/`certificate` → `:tls`; `Permission denied (publickey)`/`Authentication failed`/`could not read Username` → `:auth`; ไม่รู้จัก → nil
- Produces `Kong::Client::NetworkUnreachable < Kong::Client::UpstreamUnavailable` พร้อม `#kind` — เป็น subclass เพื่อให้ `rescue UpstreamUnavailable` เดิมทุกจุดยังจับได้
- Produces `Kong::ErrorExplanation.for(error, network_note: nil) -> Result` โดย `Result = Struct.new(:key, :title, :cause, :next_step, keyword_init: true)` และ `Result#to_flash -> Hash`; `next_step` ของ key `network_*` ต่อท้ายด้วย `network_note` ถ้ามี (R1 ส่งค่า `project.network_note`)
- mapping: `Unauthorized→unauthorized`, `Forbidden→forbidden`, `RouteNotMatched→route_not_matched`, `EntityNotFound→entity_not_found`, `RateLimited→rate_limited`, `NetworkUnreachable(kind)→network_dns_failed | network_refused | network_timed_out | network_tls_failed | connection_failed`, `UpstreamUnavailable→upstream_unavailable`, `UnexpectedResponse→unexpected_response`, `Faraday::Error` อื่น → ผ่าน `NetworkFailure.classify` เหมือนกัน, อื่นๆ → `connection_failed`
- error อื่นที่ R6/R7/R8 นำมาใช้ (`Kong::PrometheusClient::*`, `Kong::DeckCli::Error`, `Kong::GitClient::Error`) เพิ่ม mapping ใน task ของตัวเอง

- [x] **Step 1: test**

```ruby
# spec/services/kong/network_failure_spec.rb
require "rails_helper"

RSpec.describe Kong::NetworkFailure do
  {
    Faraday::ConnectionFailed.new(SocketError.new("getaddrinfo: Name or service not known")) => :dns,
    Faraday::ConnectionFailed.new(Errno::ECONNREFUSED.new("connect(2)")) => :refused,
    Faraday::TimeoutError.new("execution expired") => :timeout,
    Faraday::SSLError.new("SSL_connect returned=1 errno=0 state=error: certificate verify failed") => :tls,
    Faraday::ConnectionFailed.new("something else") => :other
  }.each do |error, kind|
    it "classifies #{error.class.name.demodulize} (#{error.message[0, 30]}) as #{kind}" do
      expect(described_class.classify(error)).to eq(kind)
    end
  end

  {
    "dial tcp: lookup kong-a-uat.internal: no such host" => :dns,
    "fatal: unable to access 'https://git.example/': Could not resolve host: git.example" => :dns,
    "dial tcp 10.0.0.5:443: connect: connection refused" => :refused,
    "dial tcp 10.0.0.5:443: i/o timeout" => :timeout,
    "x509: certificate signed by unknown authority" => :tls,
    "git@git.example: Permission denied (publickey)." => :auth,
    "deck: unknown flag" => nil
  }.each do |text, kind|
    it "classifies tool output #{text[0, 30].inspect} as #{kind.inspect}" do
      expect(described_class.classify_text(text)).to eq(kind)
    end
  end
end
```

```ruby
# spec/services/kong/client_spec.rb — เพิ่ม
it "raises NetworkUnreachable with the kind when DNS fails, still catchable as UpstreamUnavailable" do
  connection = create(:kong_connection, admin_url: "https://kong-a-uat.internal")
  stub_request(:get, "https://kong-a-uat.internal/").to_raise(Faraday::ConnectionFailed.new(SocketError.new("getaddrinfo: Name or service not known")))
  expect { described_class.new(connection: connection, secret: "pw").get("/") }.to raise_error(Kong::Client::NetworkUnreachable) { |e|
    expect(e.kind).to eq(:dns)
    expect(e).to be_a(Kong::Client::UpstreamUnavailable)
    expect(e.message).not_to include("pw")
  }
end

it "keeps a real 502 from the loopback service as plain UpstreamUnavailable" do
  connection = create(:kong_connection, admin_url: "https://kong.test")
  stub_request(:get, "https://kong.test/").to_return(status: 502, body: "{}")
  expect { described_class.new(connection: connection, secret: "pw").get("/") }.to raise_error { |e|
    expect(e.class).to eq(Kong::Client::UpstreamUnavailable)
  }
end
```

```ruby
# spec/services/kong/error_explanation_spec.rb
require "rails_helper"

RSpec.describe Kong::ErrorExplanation do
  {
    Kong::Client::Unauthorized => "unauthorized",
    Kong::Client::Forbidden => "forbidden",
    Kong::Client::RouteNotMatched => "route_not_matched",
    Kong::Client::EntityNotFound => "entity_not_found",
    Kong::Client::RateLimited => "rate_limited",
    Kong::Client::UpstreamUnavailable => "upstream_unavailable",
    Kong::Client::UnexpectedResponse => "unexpected_response"
  }.each do |klass, key|
    it "explains #{klass.name.demodulize} with its own cause and next step" do
      result = described_class.for(klass.new("x"))
      expect(result.key).to eq(key)
      expect([ result.title, result.cause, result.next_step ]).to all(be_present)
    end
  end

  { dns: "network_dns_failed", refused: "network_refused", timeout: "network_timed_out", tls: "network_tls_failed", other: "connection_failed" }.each do |kind, key|
    it "explains an unreachable #{kind} as #{key}, not as the Admin API being down" do
      result = described_class.for(Kong::Client::NetworkUnreachable.new("x", kind: kind))
      expect(result.key).to eq(key)
      expect(result.cause).not_to match(/admin api .*(down|not listening)/i)
    end
  end

  it "adds the project's network note to the next step of a network problem" do
    result = described_class.for(Kong::Client::NetworkUnreachable.new("x", kind: :timeout),
      network_note: "Reachable from the NONPROD VPN only")
    expect(result.next_step).to include("Reachable from the NONPROD VPN only")
  end

  it "classifies a bare Faraday error the same way instead of raising" do
    expect(described_class.for(Faraday::ConnectionFailed.new(SocketError.new("getaddrinfo failed"))).key).to eq("network_dns_failed")
  end

  it "never tells a read-only credential that the entity is missing" do
    ro = described_class.for(Kong::Client::RouteNotMatched.new("x"))
    expect(ro.cause).not_to match(/not found|does not exist/i)
  end
end
```

```ruby
# spec/requests/sessions_spec.rb — เพิ่ม
it "explains a wrong password with a cause and what to do next" do
  connection = create(:kong_connection, admin_url: "https://kong.test")
  stub_request(:get, "https://kong.test/").to_return(status: 401, headers: { "WWW-Authenticate" => "Basic" },
    body: { message: "Unauthorized" }.to_json)
  post login_connection_path(connection), params: { username: "a", password: "b" }
  expect(response.body).to include(I18n.t("hints.errors.unauthorized.next_step"))
end

it "says the connection's network is out of reach instead of 'Admin API down' when DNS fails" do
  connection = create(:kong_connection, admin_url: "https://kong-a-uat.internal")
  stub_request(:get, "https://kong-a-uat.internal/").to_raise(Faraday::ConnectionFailed.new(SocketError.new("getaddrinfo: Name or service not known")))
  post login_connection_path(connection), params: { username: "a", password: "b" }
  expect(response.body).to include(I18n.t("hints.errors.network_dns_failed.title"))
  expect(response.body).not_to include(I18n.t("hints.errors.upstream_unavailable.title"))
end
```

- [x] **Step 2:** FAIL → implement `NetworkFailure` → `Client::NetworkUnreachable` (`def initialize(message, kind:, response: nil)`; ใน `Client#request` rescue ใช้ `NetworkFailure.classify(e)`; ข้อความ = `"Kong Admin API unreachable at #{@connection.admin_url} (#{kind})"` ไม่ต่อ `e.message` ที่อาจมี URL พร้อม userinfo) → `ErrorExplanation` (อ่าน `I18n.t("hints.errors.#{key}.title")` ฯลฯ) → PASS
- [x] **Step 3:** `Kong::ConnectionLogin` บันทึก `last_status` ของ `NetworkUnreachable` เป็น `"unavailable"` เหมือนเดิม (R1.11 แยกเป็น `"unreachable"`) — ตรวจว่า spec เดิมของ login ยังผ่าน
- [x] **Step 4:** ใน `EntitiesController`/`PluginsController` ทุก `rescue Kong::Client::Error => e` ใส่ `flash[:error_explanation] = Kong::ErrorExplanation.for(e).to_flash` (สำหรับ `render` ใช้ `flash.now`) ข้อความ alert เดิมคงไว้ · request spec: plan create ที่ Kong ตอบ 404 no-route → `flash[:error_explanation]["key"] == "route_not_matched"`
- [x] **Step 5:** suite 0 failures · Commit `feat(R3.2): every Kong error names its cause and next step; network trouble is told apart from Kong being down`

**เกณฑ์ผ่าน:** ทุก example ใหม่ผ่าน · ไม่มี controller ใดต่อ `e.message` ของ Faraday เข้าหน้าเว็บโดยไม่ผ่าน explanation · `rescue Kong::Client::UpstreamUnavailable` เดิมยังจับ network failure ได้ (suite เดิมผ่าน)

---

### Task R3.3: schema fields สำหรับ reference panel (backend)

**ชั้น:** backend · **ต้องเสร็จก่อน:** R3.1 · **ไฟล์ที่แก้ได้:**
- Create: `app/services/kong/entity_schema.rb`, `spec/services/kong/entity_schema_spec.rb`
- Modify: `app/controllers/entities_controller.rb` (`new`, `edit`, `render_new_with_error` ตั้ง `@schema_fields`), `spec/requests/entities_spec.rb`

**Interfaces:** Produces `Kong::EntitySchema.fields(client:, entity_type:) -> Array<Hash> | nil` — flatten `GET /schemas/<Kong::EntityTypes.fetch(type).schema_name || type+"s">` เป็น `{name:, type:, required:, default:, one_of:, nested:}` · ตัด `Kong::EntityTypes::KONG_MANAGED_FIELDS` · nil เมื่อ `Kong::Client::Error`

- [x] **Step 1: test**

```ruby
require "rails_helper"

RSpec.describe Kong::EntitySchema do
  let(:connection) { create(:kong_connection, admin_url: "https://kong.test") }
  let(:client) { Kong::Client.new(connection: connection, secret: "pw") }

  it "flattens Kong's upstream schema into reference rows, without Kong-managed fields" do
    stub_request(:get, "https://kong.test/schemas/upstreams").to_return(status: 200, body: { fields: [
      { id: { type: "string", auto: true } },
      { name: { type: "string", required: true } },
      { algorithm: { type: "string", default: "round-robin", one_of: %w[consistent-hashing least-connections round-robin] } }
    ] }.to_json)

    rows = described_class.fields(client: client, entity_type: "upstream")
    expect(rows.map { _1[:name] }).to eq(%w[name algorithm])
    expect(rows.last).to include(default: "round-robin", one_of: include("least-connections"))
  end

  it "returns nil when Kong cannot be read, so the page falls back to hints alone" do
    stub_request(:get, "https://kong.test/schemas/upstreams").to_return(status: 503, body: "{}")
    expect(described_class.fields(client: client, entity_type: "upstream")).to be_nil
  end
end
```

- [x] **Step 2:** FAIL → implement → PASS · ตั้ง `@schema_fields` ใน controller + request spec ว่า `entities#new?type=upstream` ตอบ 200 เมื่อ schema 503
- [x] **Step 3:** ยืนยัน path schema ของแต่ละ type กับ compose (GET เท่านั้น): `/schemas/upstreams`, `/schemas/targets`, `/schemas/certificates`, `/schemas/ca_certificates`, `/schemas/snis`, `/schemas/consumers` → ถ้า path ใดไม่ใช่ ให้ใช้ `schema_name` จาก registry
- [x] **Step 4:** suite 0 failures · Commit `feat(R3.3): entity forms get Kong's own schema as reference rows`

---

### Task R3.4: ชิ้นส่วน hint + toggle (UI)

**ชั้น:** UI · **ต้องเสร็จก่อน:** R3.1, R3.2 · **ไฟล์ที่แก้ได้:**
- Create: `app/views/shared/_field_hint.html.erb`, `app/views/shared/_empty_state.html.erb`, `app/views/shared/_risk_notice.html.erb`, `app/views/shared/_error_explanation.html.erb`, `app/views/shared/_hint_toggle.html.erb`, `app/views/shared/_schema_reference.html.erb` (ย้ายจาก `plugins/_schema_reference`), `app/helpers/hints_helper.rb`, `app/javascript/controllers/hint_toggle_controller.js`, `spec/helpers/hints_helper_spec.rb`
- Modify: `app/views/layouts/application.html.erb` (toggle ใน topbar + `_error_explanation` ใต้ alert), `app/assets/tailwind/application.css`, `app/views/plugins/new.html.erb` (render partial ใหม่), `spec/requests/ui_snapshots_spec.rb`

**คำสั่ง:** `/impeccable shape shared hint components` → `/impeccable onboard` → `/impeccable harden`
บอก Impeccable: design system อยู่ที่ `docs/UI-DESIGN.md` (ห้ามเขียนทับ `docs/DESIGN.md`)

**Interfaces (helper — presentational):**
- `field_hint(form, field, id:)` → `<p id=…>` help + `<span>` "e.g. …" ; ส่วน "detail" (ถ้ามี key `detail`) แสดงเมื่อ `detailed_hints?`
- `hint_describedby(form, field)` → id สำหรับ `aria-describedby`
- `empty_state(page, **interpolations)` → render `_empty_state`
- `risk_notice(situation, **interpolations)` → render `_risk_notice`

- [x] **Step 1:** helper spec (เขียนก่อน)

```ruby
require "rails_helper"

RSpec.describe HintsHelper, type: :helper do
  before do
    I18n.backend.store_translations(:en, hints: { fields: { demo: { host: {
      help: "Where Kong sends the request.", example: "payments.internal", detail: "Longer explanation." } } } })
  end

  it "renders help and example, linked by id for aria-describedby" do
    allow(helper).to receive(:detailed_hints?).and_return(true)
    html = helper.field_hint(:demo, :host, id: "demo-host-hint")
    expect(html).to include('id="demo-host-hint"', "Where Kong sends the request.", "payments.internal", "Longer explanation.")
  end

  it "drops only the detail in compact mode -- help and example always stay" do
    allow(helper).to receive(:detailed_hints?).and_return(false)
    html = helper.field_hint(:demo, :host, id: "x")
    expect(html).to include("payments.internal")
    expect(html).not_to include("Longer explanation.")
  end
end
```

- [x] **Step 2:** รัน `/impeccable shape` → สร้าง partial/CSS ตามผลลัพธ์ที่ยึด `UI-DESIGN.md` (hairline, `text-xs` 13px, ink-soft, ไม่มีไอคอนใหม่, ไม่มีสีใหม่)
- [x] **Step 3:** toggle: `<form>` PATCH ไป `hint_preference_path` ทำงานได้ไม่มี JS; `hint_toggle_controller.js` แค่ submit ด้วย `requestSubmit()` และอัปเดต `aria-pressed`
- [x] **Step 4:** `bundle exec rspec spec/helpers/hints_helper_spec.rb spec/requests` → PASS
- [x] **Step 5:** เพิ่ม snapshot `layout-compact-hints` + `plugins-config` แล้ว `UI_SNAPSHOTS=1 bundle exec rspec spec/requests/ui_snapshots_spec.rb && npx impeccable detect tmp/ui-snapshots`
- [x] **Step 6:** Commit `feat(R3.4): shared hint, empty-state, risk and error pieces with a remembered hide switch`

**เกณฑ์ detect:** ไม่มี finding หลักเพิ่มจาก baseline บน snapshot ที่แตะ · ตรวจ 390px ไม่มี horizontal scroll

---

### Task R3.5: เขียนเนื้อหา hint ของหน้าที่มีอยู่ (UI — microcopy)

**ชั้น:** UI · **ต้องเสร็จก่อน:** R3.4, R3.3 · **ไฟล์ที่แก้ได้:** `config/locales/hints.en.yml` เท่านั้น

**คำสั่ง:** `/impeccable clarify config/locales/hints.en.yml` (บริบท: ผู้อ่านรู้ HTTP/API แต่ไม่รู้ Kong และธรรมเนียมทีม)

รายการที่ต้องมีครบ (ทุก key มี `help` 1–2 บรรทัด และ `example`):

| กลุ่ม | key |
|---|---|
| connection form | name, env (R1 เปลี่ยน), admin_url, verify_ssl, ca_bundle_path, apply_mode, credential_mode, select_tags |
| login | username, password, operator |
| upstream | name, algorithm, hash_on, hash_fallback, slots, healthchecks, host_header, tags |
| target | target, weight, tags |
| certificate | cert, key (vault reference), snis, tags |
| ca_certificate | cert, tags |
| sni | name, certificate, tags |
| consumer | username, custom_id, tags |
| plugin (ส่วนกลาง) | scope, enabled, protocols, tags |
| entity edit (fields tab) | tags, enabled |
| errors | unauthorized, forbidden, route_not_matched, entity_not_found, rate_limited, upstream_unavailable, unexpected_response, connection_failed, network_dns_failed, network_refused, network_timed_out, network_tls_failed (ข้อความต้องบอกว่า "เครื่องนี้อาจไม่ได้อยู่ใน network ของ project" และให้ network note ต่อท้ายได้) |
| empty_states | connections, entities (แยก "never synced" กับ "no match"), plugins_catalog, change_plans (pending PRs), audit_events, tokens, certificates_expiring, entity_children (routes/plugins/targets/snis/credentials) |
| risks | delete_entity, delete_admin_path, rank_2_login (uat + prod — แทนคำเตือนที่มีแค่ prod), rank_2_apply, shared_credential_write, env_var_certificate |
| pages.intro | ทุกหน้าที่มี h1 |

- [x] **Step 1:** เขียนทุก key · ที่ไม่มั่นใจ (ธรรมเนียมทีม, ค่าตัวอย่างของทีม, owner) → `To Edit: <ร่าง>`
- [x] **Step 2:** `bin/rails hints:todo` → แนบรายการในรายงาน
- [x] **Step 3:** ตรวจ: ไม่มี example ที่เป็น hostname/credential จริง (`grep -nE "password|secret" config/locales/hints.en.yml` ต้องเป็นคำอธิบายเท่านั้น)
- [x] **Step 4:** Commit `docs(R3.5): hints for every existing field, empty state, risk and error`

---

### Task R3.6: retrofit หน้าที่มีอยู่ (UI)

**ชั้น:** UI · **ต้องเสร็จก่อน:** R3.5 · **ไฟล์ที่แก้ได้:** `app/views/connections/*`, `app/views/sessions/new.html.erb`, `app/views/entities/*`, `app/views/plugins/*`, `app/views/change_plans/*`, `app/views/audit_events/index.html.erb`, `app/views/personal_access_tokens/*`, `app/views/certificates/expiring.html.erb`, `app/views/health/show.html.erb`, `app/assets/tailwind/application.css`, `spec/requests/ui_snapshots_spec.rb`, `spec/requests/consistency_spec.rb` (เพิ่ม assertion เท่านั้น)

**คำสั่ง:** `/impeccable onboard app/views` → `/impeccable clarify app/views` → `/impeccable harden app/views`

- [x] **Step 1:** เพิ่ม assertion (เขียนก่อน) ใน `consistency_spec.rb`:
  - ทุก `<input>`, `<select>`, `<textarea>` ที่มองเห็นในหน้าฟอร์มที่มีอยู่มี `aria-describedby` ที่ชี้ไป element ที่มีข้อความ
  - หน้า entities index ที่ไม่มีข้อมูลเลย (ไม่เคย sync) แสดงข้อความของ `hints.empty_states.entities.never_synced.title` และเมื่อ filter ไม่เจอแสดง `…no_match.title`
  - หน้า login ของ uat แสดง `hints.risks.rank_2_login.title`
- [x] **Step 2:** รัน → FAIL
- [x] **Step 3:** ใช้ `field_hint` / `empty_state` / `risk_notice` แทนข้อความที่เขียนตรงใน view; JSON editor pages แสดง `shared/_schema_reference` จาก `@schema_fields` + `field_hint` ต่อ field (fallback เป็น hint อย่างเดียวถ้า `@schema_fields` nil)
- [x] **Step 4:** PASS · `UI_SNAPSHOTS=1 …` + `npx impeccable detect tmp/ui-snapshots`
- [x] **Step 5:** เปิดแอปจริง (`bin/dev` + compose) ถ่าย 390px + 1280px: connections, login uat, entities (ว่าง/มีข้อมูล), new upstream, plugin config, plan review
- [x] **Step 6:** Commit `feat(R3.6): every existing page explains its fields, empty states and risks`

**เกณฑ์ detect:** จำนวน finding หลักบน snapshot ≤ baseline · `/impeccable audit app/views` H10 (Help) ≥ 3

---

### Task R3.7: ตรวจรับของเจ้าของงาน (manual)

**ชั้น:** — · **ต้องเสร็จก่อน:** R3.6 และ **R2 ทั้งหมด** (เกณฑ์ "สร้าง service และ route แรก" ต้องมีฟอร์มของ R2)

- [ ] เจ้าของงานตรวจ `bin/rails hints:todo` จนว่าง หรือยอมรับรายการที่เหลือเป็นลายลักษณ์อักษร
- [ ] ทดสอบกับคน 1 คนที่ไม่เคยใช้ Kong บน compose `local/dev`: ภารกิจ "สร้าง service `echo` ชี้ `http://httpbin.org` และ route `/echo` แล้วเรียกผ่าน proxy ให้ได้ 200" ห้ามเปิดเอกสาร · จดเวลา, จุดที่ติด, คำถามที่ถาม
- [ ] จุดที่ติด → แก้ใน `hints.en.yml` (UI task เพิ่ม — หยุดถามก่อนเพิ่ม)

**รอบที่ 1 (2026-09-26, เจ้าของงานทดสอบเองบน compose หลัง R2):** uat สร้าง service ได้ · ไม่เห็นปุ่มบน `default/dev-readonly` = ถูกต้อง ·
ติด "ข้อความเยอะเกินไปทุกหน้า" → hint เป็นแบบกระชับโดยค่าเริ่มต้น (`d635930`) + distill หน้า R2 (`18960df`) + หน้าอื่นแนวเดียวกัน (`dd6f7f6`) ·
ยังค้าง: ทดสอบกับคนที่ไม่เคยใช้ Kong · `bin/rails hints:todo` เหลือ 5 (`errors.forbidden.next_step`, `errors.upstream_unavailable.next_step`,
`errors.git_auth_failed.*` ×3) รอเจ้าของงานตรวจ

## เกณฑ์ปิดงาน R3

- [x] ทุก field ในฟอร์มที่มีอยู่มี help + example จาก `hints.en.yml` (consistency_spec)
- [x] ทุกหน้ามี empty state ที่บอกว่าใช้ทำอะไรและเริ่มอย่างไร
- [x] ลบ / rank ≥ 2 / admin path มีคำอธิบายผลกระทบก่อนยืนยัน
- [x] error 6 แบบ (+ unexpected, connection_failed, network_* 4 ชนิด) มี cause + next step · ปัญหาเครือข่ายไม่ถูกรายงานเป็น "Admin API ล่ม"
- [x] ปิด hint แล้วยังปิดหลัง reload (request spec)
- [x] hint อยู่ใน `hints.en.yml` ไฟล์เดียว (`grep -rn "e\.g\." app/views` ไม่เจอข้อความ hint ที่เขียนตรง)
- [x] `bundle exec rspec` 0 failures · detect ไม่เพิ่มจาก baseline · ภาพหน้าจอแนบ
- [ ] R3.7 ทำหลัง R2 (บันทึกผลใน plan นี้)

### ผลตรวจเกณฑ์ปิดงาน (2026-09-25, cloud session)

- `bundle exec rspec`: **951 examples, 0 failures** (T0 ปิดที่ 889) · MCP vitest 28/28 · `log_filtering_spec` 3/0
  (รันบน Ruby 3.3.6 เพราะ proxy ของ cloud บล็อก `cache.ruby-lang.org` ติดตั้ง 3.4.6 ไม่ได้ — ควรรันซ้ำบน 3.4.6 ในเครื่อง)
- field: `consistency_spec` "hints" ครอบฟอร์ม connection, login, token, entity edit + filter, JSON editor, plugin config
- empty state: `hints.empty_states.*` ถูกใช้ครบ 8 ชุด (connections, entities ×3, plugins_catalog, change_plans, audit_events,
  tokens, certificates_expiring, entity_children)
- error: ทั้ง 12 key ใต้ `hints.errors` มี `title` / `cause` / `next_step` · `error_explanation_spec` ตรวจว่า network_* ไม่ถูกอธิบายเป็น Admin API ล่ม
- ปิด hint: `hint_preferences_spec` (cookie ถาวร อ่านฝั่ง server)
- detect บน snapshot: **44 findings บน 33 หน้า** (warning 39, advisory 5) เทียบ baseline 44 บน 31 หน้า
  - หน้าที่มีทั้งสองรอบ: 42 → 39 (change-plan-delete 6→5, entity-show 4→2, หน้าอื่นเท่าเดิม) ไม่มี finding ใหม่
  - หน้าใหม่ของ R3: login-uat 2 (`side-tab` ของ `env-notice` ที่มีตั้งแต่ก่อน R3 + cramped-padding), layout-compact-hints 2, alert-error-explanation 1
  - `connections-index` ไม่ถูกเขียนลง `tmp/ui-snapshots` แล้ว (ย้ายไป tmpdir ใน `d60c094`) — หน้านี้หลุดจาก detect
- 390px: ไม่มี horizontal scroll ใน 9 หน้าที่ถ่าย · ภาพหน้าจอ 390 + 1280 ถ่ายจาก snapshot (ไม่มี Docker/compose ใน cloud) แนบในรายงาน ไม่ commit
- `grep "Basic " log/test.log`: เจอ 1 แถว = fixture `"Basic abc"` ใน config ของ plugin ที่ spec ของ scrub ใส่เอง ไม่ใช่ header ของ request
- `bin/rails hints:todo`: เหลือ 4 รายการ (`connection.name.detail`, `connection.select_tags_raw.detail`,
  `errors.forbidden.next_step`, `errors.upstream_unavailable.next_step`) — รอเจ้าของงานใน R3.7

**ข้อค้าง (เจ้าของงานตัดสิน 2026-09-25):**

1. `hints.risks.rank_2_apply` มีใน `hints.en.yml` แต่ไม่มี view ไหนใช้ (คำเตือน rank ≥ 2 ตอน apply เขียนใน
   `change_plans/show.html.erb` อยู่แล้ว) → **ลบ key ที่ไม่ใช้** · `fix(R3.review)`
2. `connections-index` หลุดจาก `tmp/ui-snapshots` → **เพิ่มกลับ** · `test(R3.review)` · detect หลังเพิ่ม: **46 findings บน 34 หน้า**
   (connections-index 2 = baseline) · หน้าที่มีทั้งสองรอบ 44 → 41 · rspec 952/0
