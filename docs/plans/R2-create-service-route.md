# R2 — Create service and route Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** ฟอร์มทำมือสำหรับสร้าง service และ route (route สร้างใต้ service) ที่ตรวจค่าก่อนส่ง, ใส่ `select_tags` อัตโนมัติ, เตือน route ที่ทับกัน, direct → หน้า review plan, pr → เข้า changeset (R8) โดยไม่เรียก Admin API แบบเขียน และซ่อนปุ่มเมื่อเขียนไม่ได้

**Architecture:** form object (`ServiceForm`, `RouteForm` — ActiveModel) แปลง params → attributes ของ Kong แล้วส่ง `Kong::ChangePlanner` เดิม; `ChangePlanner` เติม `select_tags` ให้ทุก create (คน + agent ได้กฎเดียวกัน); `Kong::RouteOverlap` อ่าน read-model (+ รายการ create ใน changeset) เท่านั้น; `can_propose_writes?` เป็นคำตอบเดียวว่าจะแสดงปุ่มเขียนไหม

**Tech Stack:** Rails 8.1 ActiveModel, Stimulus (ตรวจ overlap สด), RSpec + WebMock

**Spec:** `docs/requirements/R2-create-service-route.md` (+ `design-amendments.md` §C3), `docs/plans/00-roadmap.md` (Q13, Q20, Q21)

## Global Constraints

- PR mode: ไม่มี request `POST/PUT/PATCH/DELETE` ไปที่ Kong — มี test ยืนยัน (request spec + planner spec)
- ปุ่มสร้างแสดงเมื่อ `apply_mode == "pr"` หรือ (`apply_mode == "direct"` และ `access_level == "rw"`) เท่านั้น
- route ต้องมี `name` (decK ต้องการ — DESIGN §8 M5c)
- ชื่อ service/route: `/\A[A-Za-z0-9._~-]+\z/` (ตัวอักษรที่ Kong ยอมให้ใช้ใน name)
- overlap เป็นคำเตือน ไม่ block
- ไม่มีค่าตั้งต้นต่อ project, ไม่มี promote flow (Q20)
- hint ทุก field อยู่ใน `hints.fields.service.*` / `hints.fields.route.*`

## Review Focus

1. route ใหม่ path `/api` ขณะมี route เดิม `/api/v1` บน host เดียวกัน → เตือน (prefix) ทั้งสองทิศ — test ใน R2.3
2. route เดิมไม่มี `hosts` (ตอบทุก host) + route ใหม่มี host → ถือว่าทับ — test ใน R2.3
3. wildcard `*.example.com` กับ `api.example.com` → ทับ; `*.example.com` กับ `example.com` → ไม่ทับ — test ใน R2.3
4. ผู้ใช้กรอก tag ที่ซ้ำกับ select_tag หรือว่าง → tags ไม่ซ้ำ ไม่มีค่าว่าง — test ใน R2.1
5. service ที่สร้างใน changeset (ยังไม่อยู่ใน Kong) → หน้า "Add route" ใช้ได้และ route เข้า changeset เดียวกัน — test ใน R2.4

---

## Spec ที่ตกลงแล้ว

**Service fields:** `name`*, `protocol` (http/https/grpc/grpcs, default http), `host`*, `port` (default ตาม protocol: 80/443), `path` (ต้องขึ้นต้น `/`), `retries` (0–32767, default 5), `connect_timeout`/`read_timeout`/`write_timeout` (ms, 1–2147483646, default 60000), `enabled` (default true), `tags`

**Route fields:** `name`*, `protocols` (http,https default), `methods` (เลือกหลายค่า: GET POST PUT PATCH DELETE OPTIONS HEAD), `hosts` (คั่นบรรทัด), `paths` (คั่นบรรทัด; ขึ้นต้น `/` หรือ `~` สำหรับ regex), `strip_path` (default true), `preserve_host` (default false), `tags` · ต้องมีอย่างน้อยหนึ่งใน methods/hosts/paths

**Overlap (Q21):** ทับ = host ทับ ∧ method ทับ ∧ path ทับ
- host: ฝั่งใดว่าง = ทุก host; เทียบ exact (ไม่สนตัวพิมพ์); `*.a.b` match `x.a.b` (ชั้นเดียวขึ้นไป) ไม่ match `a.b`; `a.*` match `a.x`
- method: ฝั่งใดว่าง = ทุก method; ไม่งั้นต้อง intersect
- path: ฝั่งใดว่าง = `/`; เท่ากัน หรือฝั่งหนึ่งเป็น prefix ของอีกฝั่ง → ทับ; ฝั่งใดเป็น regex (`~`) → ผล `:unknown` "can't tell — regex path"
- ผล: `Array<{route_name:, service_name:, reason: :exact | :prefix | :unknown}>`

**Preview:** direct → หน้า review plan เดิม (ตาราง "New value") + overlap; pr → หน้า changeset preview (R8)

## Contract UI ↔ backend

| backend ให้ | รายละเอียด |
|---|---|
| routes | `resources :services, only: %i[new create]` · `resources :routes, only: %i[new create]` (param `service_id` = kong id หรือ provisional id) · `get "routes/overlap" => "routes#overlap", as: :routes_overlap` (JSON) |
| `@form` | `ServiceForm` / `RouteForm` (ActiveModel: `errors`, attribute readers, `PROTOCOLS`, `METHODS`) |
| `@service_label` (routes#new) | ชื่อ service (read-model หรือ changeset) |
| `GET /routes/overlap?hosts[]=&paths[]=&methods[]=` | `{ "overlaps": [ {route_name, service_name, reason} ] }` — อ่าน read-model ของ connection ปัจจุบันเท่านั้น |
| `@route_overlaps` (change_plans#show, route create) | รูปแบบเดียวกับ JSON |
| `can_propose_writes?` (helper_method) | ตามกฎใน Global Constraints |
| create response | direct → `redirect_to change_plan_path(plan)`; pr → `redirect_to changeset_path(plan.changeset)` + notice "Added to changeset" |
| error | `render :new, status: 422` พร้อม `@form.errors`; Kong error → `flash.now[:error_explanation]` (R3.2) |

---

### Task R2.1: `ServiceForm` (backend)

**ชั้น:** backend · **ต้องเสร็จก่อน:** R1, R8, R3.1 · **ไฟล์ที่แก้ได้:** Create `app/forms/service_form.rb`, `spec/forms/service_form_spec.rb`

**Interfaces:** `ServiceForm.new(params_hash)`; `#valid?`; `#to_attributes(select_tags:) -> Hash` (string keys, พร้อมส่ง ChangePlanner)

- [x] **Step 1: test**

```ruby
require "rails_helper"

RSpec.describe ServiceForm do
  let(:valid) { { name: "billing", protocol: "http", host: "billing.internal", port: "8080", path: "/api",
                  retries: "5", connect_timeout: "60000", read_timeout: "60000", write_timeout: "60000", enabled: "1", tags: "team-a, payments" } }

  it "builds Kong's service body with typed values" do
    attrs = described_class.new(valid).to_attributes(select_tags: [])
    expect(attrs).to include("name" => "billing", "protocol" => "http", "host" => "billing.internal", "port" => 8080,
      "path" => "/api", "retries" => 5, "enabled" => true, "tags" => %w[team-a payments])
  end

  it "adds the connection's select_tags without duplicates or blanks" do
    attrs = described_class.new(valid.merge(tags: "managed-by-kongctl, , team-a")).to_attributes(select_tags: %w[managed-by-kongctl])
    expect(attrs["tags"]).to eq(%w[managed-by-kongctl team-a])
  end

  it "defaults the port from the protocol" do
    expect(described_class.new(valid.merge(protocol: "https", port: "")).to_attributes(select_tags: [])["port"]).to eq(443)
  end

  {
    name: [ "bad name", "must use letters, digits, . _ ~ -" ],
    host: [ "", "can't be blank" ],
    port: [ "70000", "must be between 1 and 65535" ],
    path: [ "api", "must start with /" ],
    read_timeout: [ "0", "must be between 1 and 2147483646" ],
    protocol: [ "ftp", "is not included in the list" ]
  }.each do |field, (value, message)|
    it "rejects #{field}=#{value.inspect}" do
      form = described_class.new(valid.merge(field => value))
      expect(form).not_to be_valid
      expect(form.errors[field].join).to include(message)
    end
  end

  it "omits empty optional fields instead of sending nulls (decK rejects null)" do
    attrs = described_class.new(valid.merge(path: "")).to_attributes(select_tags: [])
    expect(attrs).not_to have_key("path")
  end
end
```

- [x] **Step 2:** FAIL → implement (`include ActiveModel::Model, ActiveModel::Attributes`) → PASS
- [x] **Step 3:** Commit `feat(R2.1): service form object validates and builds Kong's service body`

---

### Task R2.2: `RouteForm` (backend)

**ชั้น:** backend · **ต้องเสร็จก่อน:** R2.1 · **ไฟล์ที่แก้ได้:** Create `app/forms/route_form.rb`, `spec/forms/route_form_spec.rb`

**Interfaces:** `RouteForm.new(params_hash)`; `#to_attributes(select_tags:, service_kong_id:) -> Hash` (ใส่ `"service" => {"id" => service_kong_id}`); `#hosts_list`, `#paths_list`, `#methods_list`

- [x] **Step 1: test**

```ruby
require "rails_helper"

RSpec.describe RouteForm do
  let(:valid) { { name: "billing-v1", protocols: %w[http https], methods: %w[GET POST], hosts: "api.example.com\n",
                  paths: "/billing\n~/billing/v[0-9]+$", strip_path: "1", preserve_host: "0", tags: "" } }

  it "builds Kong's route body under its service" do
    attrs = described_class.new(valid).to_attributes(select_tags: %w[managed-by-kongctl], service_kong_id: "s-1")
    expect(attrs).to include("name" => "billing-v1", "protocols" => %w[http https], "methods" => %w[GET POST],
      "hosts" => %w[api.example.com], "paths" => [ "/billing", "~/billing/v[0-9]+$" ], "strip_path" => true,
      "preserve_host" => false, "tags" => %w[managed-by-kongctl], "service" => { "id" => "s-1" })
  end

  it "requires a name, because decK cannot place a route without one" do
    expect(described_class.new(valid.merge(name: ""))).not_to be_valid
  end

  it "requires at least one of methods, hosts or paths" do
    form = described_class.new(valid.merge(methods: [], hosts: "", paths: ""))
    expect(form).not_to be_valid
    expect(form.errors[:base].join).to match(/method, host or path/)
  end

  it "rejects a path that is neither /… nor ~regex" do
    expect(described_class.new(valid.merge(paths: "billing"))).not_to be_valid
  end

  it "rejects an invalid regex path with the regex error, not a 500" do
    form = described_class.new(valid.merge(paths: "~/billing/("))
    expect(form).not_to be_valid
    expect(form.errors[:paths].join).to match(/regex/)
  end

  it "rejects a host with a wildcard in the middle" do
    expect(described_class.new(valid.merge(hosts: "api.*.example.com"))).not_to be_valid
  end

  it "omits empty hosts/methods instead of sending empty arrays" do
    attrs = described_class.new(valid.merge(hosts: "", methods: [])).to_attributes(select_tags: [], service_kong_id: "s")
    expect(attrs.keys).not_to include("hosts", "methods")
  end
end
```

- [x] **Step 2:** FAIL → implement → PASS · Commit `feat(R2.2): route form object validates matching rules and builds Kong's route body`

---

### Task R2.3: `Kong::RouteOverlap` (backend)

**ชั้น:** backend · **ต้องเสร็จก่อน:** R2.2 · **ไฟล์ที่แก้ได้:** Create `app/services/kong/route_overlap.rb`, `spec/services/kong/route_overlap_spec.rb`

**Interfaces:** `Kong::RouteOverlap.check(connection:, hosts:, paths:, methods:, changeset: nil, exclude_kong_id: nil) -> Array<Hash>` (hash keys: `:route_name, :service_name, :reason`)

- [x] **Step 1: test**

```ruby
require "rails_helper"

RSpec.describe Kong::RouteOverlap do
  let(:connection) { create(:kong_connection) }
  let(:service) { create(:kong_entity, kong_connection: connection, entity_type: "service", name: "billing") }

  def route(name, hosts: [], paths: [], methods: [])
    create(:kong_entity, kong_connection: connection, entity_type: "route", name: name,
      parent_type: "service", parent_kong_id: service.kong_id,
      data: { "name" => name, "hosts" => hosts, "paths" => paths, "methods" => methods })
  end

  def check(**kw) = described_class.check(connection: connection, hosts: [], paths: [], methods: [], **kw)

  it "flags an identical path on the same host" do
    route("old", hosts: %w[api.example.com], paths: %w[/billing])
    expect(check(hosts: %w[api.example.com], paths: %w[/billing])).to contain_exactly(include(route_name: "old", reason: :exact))
  end

  it "flags a prefix in either direction" do
    route("v1", hosts: %w[api.example.com], paths: %w[/api/v1])
    expect(check(hosts: %w[api.example.com], paths: %w[/api]).first[:reason]).to eq(:prefix)
  end

  it "treats a route with no hosts as matching every host" do
    route("catch-all", paths: %w[/billing])
    expect(check(hosts: %w[api.example.com], paths: %w[/billing])).not_to be_empty
  end

  it "matches wildcards the way Kong does" do
    route("wild", hosts: %w[*.example.com], paths: %w[/x])
    expect(check(hosts: %w[api.example.com], paths: %w[/x])).not_to be_empty
    expect(check(hosts: %w[example.com], paths: %w[/x])).to be_empty
  end

  it "does not flag routes whose methods do not intersect" do
    route("reads", paths: %w[/billing], methods: %w[GET])
    expect(check(paths: %w[/billing], methods: %w[POST])).to be_empty
  end

  it "says it cannot tell for regex paths instead of guessing" do
    route("rx", paths: [ "~/billing/v[0-9]+$" ])
    expect(check(paths: %w[/billing/v2]).first[:reason]).to eq(:unknown)
  end

  it "ignores deleted routes and routes on other connections" do
    route("gone", paths: %w[/billing]).update!(deleted_at: Time.current)
    create(:kong_entity, entity_type: "route", data: { "paths" => %w[/billing] })
    expect(check(paths: %w[/billing])).to be_empty
  end

  it "includes routes waiting in the open changeset" do
    changeset = create(:changeset, kong_connection: connection)
    create(:change_plan, changeset: changeset, kong_connection: connection, operation: "create", entity_type: "route",
      status: "pending", after: { "name" => "queued", "paths" => %w[/billing] })
    expect(check(paths: %w[/billing], changeset: changeset).map { _1[:route_name] }).to include("queued")
  end
end
```

- [x] **Step 2:** FAIL → implement → PASS · Commit `feat(R2.3): warn when a new route overlaps an existing one`

---

### Task R2.4: controllers สร้าง service/route + auto select_tags (backend)

**ชั้น:** backend · **ต้องเสร็จก่อน:** R2.3 · **ไฟล์ที่แก้ได้:**
- Create: `app/controllers/services_controller.rb`, `app/controllers/routes_controller.rb`, `app/views/services/new.html.erb`, `app/views/routes/new.html.erb` (ขั้นต่ำ: field + label + errors), `spec/requests/services_spec.rb`, `spec/requests/routes_spec.rb`
- Modify: `config/routes.rb`, `app/services/kong/change_planner.rb` (`with_select_tags` สำหรับทุก create), `app/controllers/application_controller.rb` (`can_propose_writes?`), `app/controllers/change_plans_controller.rb` (`@route_overlaps` เมื่อ plan เป็น route create), `spec/services/kong/change_planner_spec.rb`

- [x] **Step 1: test**

```ruby
# spec/requests/services_spec.rb
require "rails_helper"

RSpec.describe "Create service", type: :request do
  include SignInHelper # from R1.7

  context "direct mode, read-write" do
    let(:connection) { create(:kong_connection, admin_url: "https://kong.test", project_env: create(:project_env, apply_mode: "direct", select_tags: %w[team-a])) }

    it "validates against Kong's schema, then opens the plan review" do
      sign_in_to(connection, access: :rw)
      stub_request(:post, "https://kong.test/schemas/services/validate").to_return(status: 200, body: "{}")
      post services_path, params: { service_form: { name: "billing", protocol: "http", host: "billing.internal" } }
      plan = ChangePlan.last
      expect(response).to redirect_to(change_plan_path(plan))
      expect(plan.after["tags"]).to eq(%w[team-a])
    end

    it "re-renders with field errors and makes no plan" do
      sign_in_to(connection, access: :rw)
      post services_path, params: { service_form: { name: "bad name", host: "" } }
      expect(response).to have_http_status(:unprocessable_entity)
      expect(ChangePlan.count).to eq(0)
    end
  end

  context "PR mode" do
    let(:connection) { create(:kong_connection, admin_url: "https://kong.test",
      project_env: create(:project_env, name: "uat", apply_mode: "pr", source: "registry", select_tags: %w[managed-by-kongctl])) }

    it "adds to the changeset and never writes to Kong" do
      sign_in_to(connection, access: :ro)
      post services_path, params: { service_form: { name: "billing", protocol: "http", host: "billing.internal" } }
      expect(response).to redirect_to(changeset_path(ChangePlan.last.changeset))
      expect(a_request(:any, /kong\.test/).with { |req| req.method != :get }).not_to have_been_made
    end
  end

  it "hides and refuses create for a read-only credential in direct mode" do
    connection = create(:kong_connection, admin_url: "https://kong.test", project_env: create(:project_env, apply_mode: "direct"))
    sign_in_to(connection, access: :ro)
    get new_service_path
    expect(response).to redirect_to(entities_path(type: "service"))
    get entities_path(type: "service")
    expect(response.body).not_to include(new_service_path)
  end
end
```

```ruby
# spec/requests/routes_spec.rb
require "rails_helper"

RSpec.describe "Create route", type: :request do
  include SignInHelper

  let(:route_params) { { route_form: { name: "billing-v1", protocols: %w[http https], paths: "/billing", methods: %w[GET] } } }

  context "direct mode" do
    let(:connection) { create(:kong_connection, admin_url: "https://kong.test", project_env: create(:project_env, apply_mode: "direct")) }
    let!(:service) { create(:kong_entity, kong_connection: connection, entity_type: "service", name: "billing") }

    before do
      sign_in_to(connection, access: :rw)
      stub_request(:post, "https://kong.test/schemas/routes/validate").to_return(status: 200, body: "{}")
    end

    it "proposes a route under the service it was opened from" do
      post routes_path, params: route_params.merge(service_id: service.kong_id)
      plan = ChangePlan.last
      expect(response).to redirect_to(change_plan_path(plan))
      expect(plan.after).to include("name" => "billing-v1", "paths" => %w[/billing], "service" => { "id" => service.kong_id })
    end

    it "answers the overlap check from the read-model" do
      create(:kong_entity, kong_connection: connection, entity_type: "route", name: "old", parent_type: "service",
        parent_kong_id: service.kong_id, data: { "name" => "old", "paths" => %w[/billing], "hosts" => [], "methods" => [] })
      get routes_overlap_path, params: { paths: %w[/billing] }
      expect(response.parsed_body["overlaps"]).to contain_exactly(include("route_name" => "old", "reason" => "exact"))
    end

    it "sends an unknown service back to the service list" do
      get new_route_path(service_id: SecureRandom.uuid)
      expect(response).to redirect_to(entities_path(type: "service"))
      expect(flash[:alert]).to be_present
    end
  end

  context "PR mode" do
    let(:connection) { create(:kong_connection, admin_url: "https://kong.test",
      project_env: create(:project_env, name: "uat", apply_mode: "pr", source: "registry", select_tags: %w[managed-by-kongctl])) }

    it "adds a route under a service that exists only in the changeset, with no write call" do
      sign_in_to(connection, access: :ro)
      post services_path, params: { service_form: { name: "billing", protocol: "http", host: "billing.internal" } }
      service_plan = ChangePlan.last

      get new_route_path(service_id: service_plan.provisional_kong_id)
      expect(response).to have_http_status(:ok)

      post routes_path, params: route_params.merge(service_id: service_plan.provisional_kong_id)
      route_plan = ChangePlan.last
      expect(route_plan).to have_attributes(changeset_id: service_plan.changeset_id, parent_kong_id: service_plan.provisional_kong_id)
      expect(a_request(:any, /kong\.test/).with { |req| req.method != :get }).not_to have_been_made
    end
  end
end
```

- [x] **Step 2:** FAIL → implement (planner: `attributes["tags"] = (connection.select_tags + Array(attributes["tags"])).uniq` เมื่อ create และ select_tags มีค่า — spec ใน `change_planner_spec.rb` สำหรับ agent create ด้วย)
- [x] **Step 3:** PASS · suite 0 failures · Commit `feat(R2.4): create services and routes through the plan or changeset pipeline`

---

### Task R2.5: ฟอร์ม service (UI)

**ชั้น:** UI · **ต้องเสร็จก่อน:** R2.4, R3.4 · **ไฟล์ที่แก้ได้:** `app/views/services/new.html.erb`, `app/views/services/_form.html.erb` (create), `app/assets/tailwind/application.css`, `config/locales/hints.en.yml` (`hints.fields.service.*`, `hints.pages.service_new.intro`), `app/javascript/controllers/service_form_controller.js` (create: ตั้ง port ตาม protocol เมื่อยังไม่ได้แก้เอง), `spec/requests/ui_snapshots_spec.rb`, `spec/requests/consistency_spec.rb` (assertion)

**คำสั่ง:** `/impeccable shape service create form` → `/impeccable onboard` → `/impeccable clarify` → `/impeccable harden`

- [x] **Step 1:** assertion (ก่อน): ทุก input มี `aria-describedby` ไปยัง hint; มีตัวอย่างค่า; timeout 3 ช่องอยู่ใน `.disclosure` "Timeouts and retries" (ค่า default แสดง); ปุ่มหลัก "Review change" (direct) / "Add to changeset" (pr)
- [x] **Step 2:** FAIL → ทำ UI (client-side validation ด้วย attribute: `required`, `pattern`, `min`/`max` ตรงกับ ServiceForm; server ยังเป็นผู้ตัดสิน)
- [x] **Step 3:** PASS · snapshot direct/pr/errors · detect · ภาพ 390/1280
- [x] **Step 4:** Commit `feat(R2.5): service form with hints and inline validation`

---

### Task R2.6: ฟอร์ม route + เตือน overlap สด (UI)

**ชั้น:** UI · **ต้องเสร็จก่อน:** R2.4, R2.5 · **ไฟล์ที่แก้ได้:** `app/views/routes/new.html.erb`, `app/views/routes/_form.html.erb` (create), `app/views/routes/_overlaps.html.erb` (create), `app/views/change_plans/show.html.erb` (ส่วน overlap), `app/javascript/controllers/route_overlap_controller.js` (create: debounce 300ms, `fetch` `routes/overlap`, render ในพื้นที่ `aria-live="polite"`), `app/assets/tailwind/application.css`, `config/locales/hints.en.yml` (`hints.fields.route.*`, `hints.risks.route_overlap.*`), `spec/requests/ui_snapshots_spec.rb`

**คำสั่ง:** `/impeccable shape route create form` → `/impeccable clarify` → `/impeccable harden`

- [x] **Step 1:** assertion (ก่อน): หน้า new route แสดงชื่อ service; หน้า review plan ของ route create ที่มี overlap แสดงชื่อ route ที่ทับและเหตุผลเป็นคำ (`Same path`, `Path prefix`, `Can't tell (regex)`)
- [x] **Step 2:** FAIL → ทำ UI · preview ของ request line ใช้ mark `.route-match` เดิม (`UI-DESIGN.md` Kong-native marks)
- [x] **Step 3:** PASS · snapshot (มี/ไม่มี overlap) · detect
- [x] **Step 4:** Commit `feat(R2.6): route form under its service, with live overlap warnings`

---

### Task R2.7: ปุ่มสร้างตามสิทธิ์ (UI)

**ชั้น:** UI · **ต้องเสร็จก่อน:** R2.4 · **ไฟล์ที่แก้ได้:** `app/views/entities/index.html.erb`, `app/views/entities/show.html.erb`, `app/views/entities/_entity.html.erb`, `config/locales/hints.en.yml`, `spec/requests/entities_spec.rb` (assertion)

**คำสั่ง:** `/impeccable clarify app/views/entities` (ข้อความเมื่อเขียนไม่ได้: "This credential is read-only on a direct-apply environment…" / "Apply mode isn't set for <project/env>…")

- [x] **Step 1:** assertion (ก่อน): Services tab มี "New service" เมื่อ `can_propose_writes?`; หน้า service มี "Add route"; ไม่มีทั้งสองเมื่อเขียนไม่ได้ และมีประโยคบอกเหตุผลแทน; ปุ่มเขียนที่มีอยู่เดิม (New upstream, New certificate, New global plugin, Edit, Delete) ใช้กฎเดียวกัน
- [x] **Step 2:** FAIL → แก้ view · PASS · detect
- [x] **Step 3:** Commit `feat(R2.7): write buttons follow one rule, and say why when hidden`

---

### Task R2.8: ตรวจ flow จริง (verification)

**ชั้น:** — · **ต้องเสร็จก่อน:** R2.1–R2.7

- [x] `local/dev` (rw): สร้าง service `echo` → review → apply → สร้าง route `/echo` → apply → ผ่าน Kong ไปถึง upstream ได้ 200
  (upstream = dev server ของ Kongsole `host.docker.internal:3000/up`; `GET /echo` ได้ 403 **จาก upstream** เพราะ Rails host authorization
  ไม่รับ Host `host.docker.internal` → เพิ่ม route `echo-host` ติ๊ก "Preserve the client's Host header" แล้ว `HEAD /echo-host` ได้ **200** จาก Rails ·
  `GET /echo-host` ยังเข้า `echo-route` เพราะ router ของ Kong ให้ route ที่มี method + path มาก่อน route ที่มีแค่ path — ตรงกับคำเตือน overlap ที่ฟอร์มแสดง)
- [x] สร้าง route `/echo/v1` → เห็นคำเตือน prefix ทั้งตอนกรอก (live region: "echo-route on echo · Path prefix") และในหน้า review (ไม่ได้ apply, plan ถูกยกเลิก)
- [x] `local/dev-ro` (ro, direct): ไม่เห็นปุ่มสร้าง มีประโยคบอกเหตุผล ("This credential can only read local/dev-ro …") · `/services/new` ส่งกลับรายการพร้อมเหตุผล
- [x] `local/uat` (pr): สร้าง service `r2-echo` + route (จากลิงก์ "Add route" ของรายการใน changeset) → อยู่ใน changeset เดียวกัน,
  route มี `parent_kong_id` = provisional id ของ service, tag `managed-by-kongctl` ครบ · YAML ที่ render จาก git (renderer ตัวเดียวกัน, เฉพาะ 2 รายการนี้)
  nest `r2-echo-route` ใต้ `r2-echo` ถูก · preview เต็มของ changeset #4 ล้มที่รายการ update ของเจ้าของงานเอง (entity ไม่อยู่ใน git — ข้อจำกัดที่บันทึกใน R8) ·
  log ของ Kong ช่วงนั้น: non-GET มีแค่ access probe ตอน login (PATCH → router 404) · เอา 2 รายการออกด้วยปุ่ม Remove แล้ว (รายการของเจ้าของงานไม่แตะ)
- [x] error: หยุด `kong-1` แล้ว apply create บน dev → plan ขึ้น Failed "Kong Admin API unreachable at http://kong-admin.internal:8000 (refused)"
  พร้อมขั้นต่อไป "Check the service in Kong before proposing this again…" · **ไม่มี** คำอธิบายแบบ R3 (cause + next step + network note)
  เพราะ `ChangePlansController#apply` ตั้งใจไม่ flash (กัน banner ซ้อน) — ส่งให้ final review ตัดสิน · start `kong-1` กลับ healthy แล้ว
- [ ] ทำ **R3.7** (ทดสอบกับคนจริง) ตอนนี้ — **รอบที่ 1 (เจ้าของงาน, 2026-09-26):** uat เห็นปุ่มและสร้างได้ ·
  "ไม่เห็นปุ่มสร้าง service" คือ `default/dev-readonly` (direct + credential อ่านอย่างเดียว) — ถูกต้องตามกฎ (เจ้าของงานยืนยัน) ·
  "ข้อความเยอะเกินไปทุกหน้า" → hint เป็นแบบกระชับโดยค่าเริ่มต้น (`d635930`) + distill หน้า R2 ผ่าน `/impeccable shape → distill → clarify` (`18960df`):
  ใต้ช่องไม่มีข้อความ (ตัวอย่างอยู่ใน placeholder "e.g. …"), ตัดประโยคใต้หัวข้อและใต้ปุ่ม, overlap เหลือหัวข้อนับจำนวน + รายการ ·
  ปุ่มเล็กในช่อง → เอา spinner ของช่องตัวเลขออก, select วาด chevron เอง · hosts/paths → แถวละค่า + Add/Remove · **รอรอบถัดไป**
- [x] ภาพหน้าจอ 390/1280: `tmp/shots/r28-*.png` (ฟอร์ม service/route, review ที่มี overlap, dev-ro, uat changeset, Kong ล่ม) + `service-new*`, `route-new*`, `change-plan-route-overlap*`

**ข้อสังเกตจากการตรวจจริง (ส่งเจ้าของงาน):** route ที่ไม่มี host จะ "ทับ" route ของ admin path (`admin-api-rw` / `admin-api-ro` มีแค่ host ไม่มี path)
เสมอ ตามนิยามใน spec (host ว่าง = ทุก host) — ถูกต้องเชิงพฤติกรรม (request ไปที่ host ของ admin จะเข้า admin route) แต่จะขึ้นในทุกฟอร์ม route ที่ไม่ใส่ host

ล้างข้อมูลทดสอบ: service `echo` + route `echo-route`/`echo-host` ลบจาก Kong dev และ read-model แล้ว · plan/audit เก็บไว้เป็นบันทึก

## Final review (2026-09-26, reviewer แยก บน Opus)

ไม่มี Critical · กฎข้อ 1–4 ไม่ถูกละเมิด · Important 2 ข้อ + ยกระดับ 1 ข้อจาก Minor → แก้ในรอบเดียว (commit `fix(R2 review)`), ทุกข้อมี test ที่เห็น RED ก่อน:
#1 ฟอร์มปฏิเสธสิ่งที่ Kong ปฏิเสธ: path บน service grpc/grpcs, host ที่ไม่ใช่ชื่อ host/IP เปล่า (มี scheme/port/path), tag ที่มี `/`, `strip_path` บน route ที่รับแค่ gRPC ·
#2 overlap ไม่นับ route ของ admin path ยกเว้น route ใหม่ระบุ host ของมัน (เดิมขึ้นเตือนทุก route ที่ไม่มี host) ·
ยกระดับ: `RoutesController` ปฏิเสธ service ของ admin path ไม่ว่า URL จะมาอย่างไร (เดิมซ่อนแค่ลิงก์)
ไม่เลือก: ให้ service/route ตรวจกับ schema ของ Kong ตอนเสนอ (จะเปลี่ยนทุก create ของ service/route รวม JSON editor)

Minor ที่เลื่อนไว้: error ตอน apply ไม่มีคำอธิบายแบบ R3 (ก่อน R2, ทุก type) · wildcard ท้าย `example.*` จับชั้นเดียว ·
ไม่ติ๊ก protocol เลย = ได้ http+https เงียบๆ · ไม่ตรวจชื่อซ้ำตอนเสนอ · route ไม่มีชื่อแสดงชื่อว่างใน overlap · comment ของ SNI ใน planner ผิดที่ ·
ไม่มี test ของ ruling R2.3 (update/delete ใน changeset แทน route เดิม) · ไม่มี JS แล้วเลือก https port ยังเป็น 80 · ข้อความ error ของ RouteForm อ่านแข็ง

## เกณฑ์ปิดงาน R2

- [ ] เกณฑ์ใน `R2-create-service-route.md` (ฉบับแก้ §C3) ครบ พร้อมหลักฐาน — **ครบยกเว้น 2 จุด:** "ผ่านเกณฑ์ของ R3" รอ R3.7 ·
  "direct: error จาก Kong แสดงตาม error mapping 6 แบบ" ตอน apply แสดงข้อความที่จำแนกแล้ว (เช่น `(refused)`) + ขั้นต่อไป แต่ยังไม่มีคำอธิบายแบบ R3 (Minor ที่เลื่อนไว้)
- [x] test "PR mode ไม่เรียก Admin API แบบเขียน" ผ่าน (request: services_spec, routes_spec · planner: change_planner_spec) · compose: non-GET มีแค่ access probe ตอน login
- [x] `bundle exec rspec` **1238/0** · vitest **31/31** · detect: 84 → 108 ทั้งหมดอยู่บนหน้าใหม่ (service-new ×3, route-new ×2, change-plan-route-overlap) เป็นชนิดที่ baseline มี ·
  `hints:todo`: ไม่มี key ใหม่ (เหลือ 5: 3 key `git_auth_failed` จาก R8 + 2 `next_step` เดิมจาก R3)
- [ ] R3.7 บันทึกผลแล้ว — **รอเจ้าของงาน**
