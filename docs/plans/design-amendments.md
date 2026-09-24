# ข้อความที่เสนอแก้ในเอกสารของทีม

AI ไม่แก้ไฟล์เหล่านี้เอง (DESIGN.md และ CLAUDE.md เป็นของทีม) — เจ้าของงานตรวจแล้วแก้เอง
หรืออนุมัติให้ AI แก้เป็น task `T0.0` (ไฟล์ requirement เท่านั้น)

## A. `docs/DESIGN.md`

### A1. §3 Login และ connection — เพิ่มแนวคิด Project

แทรกหลัง block `kong_connections`:

```ruby
projects                       # R1 — กลุ่มของ connection ที่เป็นระบบเดียวกัน
  id, key citext unique,       # ใช้ในชื่อ project/env เช่น project-a
  name, source,                # registry (connections.yml) | local (สร้างใน UI)
  git_repo, git_branch, git_web_url,   # repo แยกต่อ project
  delete_threshold,            # จำนวน delete สูงสุดต่อ changeset (default 3)
  prometheus_url, prometheus_token_encrypted   # R6

project_envs
  id, project_id, name,        # ชื่ออิสระต่อ project: dev, sit, pt, ps, nonprod …
  position,                    # ลำดับที่แสดง
  rank,                        # 0..3 — dev/sit/uat/prod ถูกบังคับค่า; ชื่ออื่นต้องเลือกเอง
  apply_mode,                  # direct | pr | NULL (= ยังไม่กำหนด → ห้ามเขียน)
  color_tag, source,
  git_path, deck_extra_paths text[], select_tags text[],
  prometheus_selector          # R6

kong_connections.project_env_id   # unique — 1 env = 1 node = 1 connection
```

แทนที่ย่อหน้า "แยก registry ออกจาก credential" ด้วย:

> `config/connections.yml` (git) เป็นที่เดียวที่กำหนด env แบบ `apply_mode: pr` ได้ เพราะ PR mode ต้องมี git repo
> env แบบ `direct` สร้างและแก้ใน UI ได้ และอยู่ใน DB ของเครื่องนั้นเท่านั้น (ป้าย "Local only")
> UI ไม่มีทางตั้งหรือถอด `pr` · ชื่อที่ใช้อ้าง connection ทุกที่ (UI, API, MCP) คือ `project/env`
> apply_mode ที่ยังไม่กำหนดไม่ใช่ `direct` — เขียนไม่ได้จนกว่าจะกำหนด

### A2. §6 Apply mode — changeset

แทนที่ขั้น 1 ของ "เส้นทางของ PR mode":

> 1. เสนอการเปลี่ยนแปลง → `change_plan` เข้า **changeset** ที่เปิดอยู่ของ connection (สร้างให้ถ้ายังไม่มี)
>    plan ใน changeset ไม่หมดอายุ 15 นาที · ดู/แก้/ลบรายการได้ก่อนส่ง
> 1b. ส่ง changeset → render ทุก plan ตามลำดับลงไฟล์เดียว → `CiGate` (admin path + delete threshold) ใน tool ก่อน push
>     → push branch `kongctl/changeset-<id>` ครั้งเดียว

### A3. §12 MCP server

- `connection` = `project/env`
- `kong_plan` บน PR mode → เพิ่มเข้า changeset คืน `changeset_id`
- `kong_apply` บน plan ที่อยู่ใน changeset → ปฏิเสธ (คนเป็นผู้ส่ง changeset เท่านั้น)
- `kong_export` → `deck gateway dump --select-tag` ผ่าน `Kong::ExportSanitizer` (ต้องระบุ `select_tags` อย่างน้อย 1 ค่า)

### A4. §15 แผนการดำเนินงาน — เพิ่ม

- **M7 — Project understanding (R5):** overview ต่อ project, request tracer, notes ใน `config/projects/<key>.md`
- **M8 — Traffic dashboard (R6):** query Prometheus ขององค์กร (Kong Prometheus plugin, `status_code_metrics: true`)
- **M6 เพิ่ม:** `kong_export` (R7)

### A5. §8 Certificate และความลับ — redactor

แทนที่ "field ที่ schema ทำเครื่องหมาย `encrypted`/`referenceable`" ด้วย:

> field ที่ schema **ของ plugin นั้นบน connection นั้น** ทำเครื่องหมาย `encrypted`/`referenceable`
> (อ่านจาก `GET /schemas/plugins/:name`, แคชต่อ connection + kong_version) ถ้าอ่าน schema ไม่ได้ ให้ redact แบบ fail-closed
> ด้วย heuristic ชื่อ field (`key|secret|password|token|credential|auth`) และ map `headers` ทั้งก้อน

## B. `CLAUDE.md` กฎข้อ 2 (ต้องแก้ก่อนเริ่ม R7)

```diff
-2. Render decK YAML จาก git ไม่ใช่จาก `deck dump` และต้องมี `_info.select_tags` เสมอ
-   (เหตุผล: `deck gateway sync` ลบทุกอย่างใน Kong ที่ไม่อยู่ในไฟล์ ถ้าไฟล์ผิดคือ outage)
+2. YAML ที่ Kongsole เขียนลง git ของ env PR mode ต้อง render จาก git ไม่ใช่จาก `deck dump`
+   และต้องมี `_info.select_tags` เสมอ
+   ข้อยกเว้นเดียว: export (R7) ใช้ `deck gateway dump --select-tag` ได้ แต่ต้องผ่าน `Kong::ExportSanitizer`
+   ทุกครั้ง (ตัด credential, private key, secret ของ plugin, entity `kong-admin-path`) ต้องมี select_tag
+   อย่างน้อย 1 ค่าและห้ามเป็น `kong-admin-path` · output ของ dump ห้ามเขียนลงดิสก์ก่อนผ่าน sanitizer
+   (เหตุผล: `deck gateway sync` ลบทุกอย่างใน Kong ที่ไม่อยู่ในไฟล์ ถ้าไฟล์ผิดคือ outage)
```

## C. ไฟล์ requirement (`T0.0` แก้จริงหลังอนุมัติ)

### C1. `docs/requirements/00-overview.md` — เกณฑ์กลาง

```diff
-- [ ] ข้อความทั้งหมดรองรับภาษาไทยโดยไม่ล้นหรือตัดคำผิด
-- [ ] test ของ backend ผ่านทั้งหมด และ `npx impeccable detect` ไม่มี finding หลักบนหน้าที่แก้
+- [ ] UI เป็นภาษาอังกฤษทั้งหมด และข้อมูลที่ผู้ใช้กรอกเป็นภาษาไทย (ชื่อ entity, notes ของ R5) แสดงได้ไม่ล้นไม่ถูกตัด
+- [ ] test ของ backend ผ่านทั้งหมด และ `npx impeccable detect` บน snapshot HTML ของหน้าที่แก้
+      (`tmp/ui-snapshots/`, ดู T0.6) ไม่มี finding หลักเพิ่มจาก baseline — detect อ่าน `.erb` ไม่ได้
```

เพิ่มในตาราง Requirements: คอลัมน์ milestone ของ R5 = M7, R6 = M8, R7 = M6

### C2. `R1-multi-project-env.md`

```diff
-- [ ] แต่ละ env กำหนด `rank` และ `apply_mode` ได้
+- [ ] env ที่ `apply_mode = pr` กำหนดได้เฉพาะใน `config/connections.yml` (ต้องมี git)
+      env ที่เป็น direct สร้างและแก้ใน UI ได้ · UI ไม่มีทางตั้งหรือถอด `pr`
+- [ ] connection ที่สร้างใน UI อยู่ใน DB ของเครื่องนั้นเท่านั้น และมีป้าย "Local only"
+      connection จาก `connections.yml` แก้ใน UI ไม่ได้
+- [ ] ชื่อ env ตั้งเองได้ต่อ project · ชื่อ dev/sit/uat/prod ได้ rank 0/1/2/3 อัตโนมัติ
+      ชื่ออื่นแสดงเป็น "other" และต้องเลือก rank 0–3 เอง ไม่มีค่า default
+- [ ] หนึ่ง env มีหนึ่ง connection
-- [ ] header แสดง project + env + สีประจำ connection ตลอดเวลา และสลับ env ภายใน project ได้ในคลิกเดียว
+- [ ] header แสดง project + env + สีประจำ connection ตลอดเวลา และ switcher แสดง env ของ project
+      ตามลำดับ คลิกแล้วไปหน้า login ของ env นั้น (login ใหม่ทุกครั้งที่สลับ)
-- [ ] MCP ยังต้องระบุ connection ชัดเจน และชื่อที่ใช้อ้างไม่กำกวมเมื่อมีหลาย project
+- [ ] MCP อ้าง connection ด้วย `project/env` เท่านั้น
```

ย้าย "คำถามค้าง" 1–5 ไปเป็น "ตัดสินแล้ว": rank ของชื่ออื่นผู้ใช้เลือก · apply_mode ตาม connections.yml/UI ·
1 env = 1 node · repo แยกต่อ project · ความดังของ UI ตาม rank, จุดสีตาม `color_tag` ของ env

### C3. `R2-create-service-route.md`

```diff
-- [ ] credential ที่เป็น read-only ไม่เห็นปุ่มสร้าง (ใช้ผล probe `access_level` ตอน login)
+- [ ] ไม่เห็นปุ่มสร้างเมื่อ apply_mode ยังไม่กำหนด หรือเป็น direct แต่ credential เป็น read-only
+      (PR mode ใช้ credential read-only โดยตั้งใจ จึงยังเห็นปุ่ม — DESIGN.md §6)
-- [ ] error จาก Kong แสดงตาม error mapping 6 แบบของ `Kong::Client` ไม่รวมเป็น "เชื่อมต่อไม่ได้"
+- [ ] direct: error จาก Kong แสดงตาม error mapping 6 แบบ · pr: error จาก git/decK แสดงข้อความของมันเอง
+- [ ] "ซ้อนกัน" = host ทับกัน (ว่าง = ทุก host, `*.x` = wildcard) และ method ทับกัน และ path ซ้ำหรือเป็น prefix
+      ของกัน · path regex (`~`) แจ้งว่า "ตรวจไม่ได้" · เป็นคำเตือน ไม่ block
```
คำถามค้าง: 1 = MCP สร้างได้ (มีอยู่แล้ว) ตามกฎ PR mode/changeset · 2 = ไม่มีค่าตั้งต้น · 3 = ไม่ทำ promote
หมายเหตุ "แก้ไขและลบ": มีอยู่แล้วผ่าน JSON editor ของทุก type

### C4. `R3-onboarding-hints.md`

```diff
-- [ ] ข้อความ hint ทั้งหมดอยู่ในที่เดียว (เช่น ไฟล์ locale) แก้ได้โดยไม่ต้องแตะ view
+- [ ] ข้อความ hint ทั้งหมด (คำอธิบาย field, ตัวอย่าง, empty state, คำอธิบายผลกระทบ, error) อยู่ใน
+      `config/locales/hints.en.yml` แก้ได้โดยไม่ต้องแตะ view · ภาษาอังกฤษทั้งหมด
+- [ ] ข้อความที่ AI ไม่มั่นใจขึ้นต้นด้วย `To Edit:` และ `bin/rails hints:todo` แสดงรายการ
+      เจ้าของงานตรวจและแก้ก่อนปิด R3 (และก่อนปิดแต่ละ R ที่เพิ่ม hint)
+- [ ] การปิด hint ผูกกับ browser (cookie) ไม่ใช่ตัวบุคคล เพราะไม่มีฐานข้อมูลผู้ใช้
```
คำถามค้าง: 1 = อังกฤษทั้งหมด · 2 = AI เขียน เจ้าของงานตรวจ · 3 = ลิงก์ภายนอกได้

### C5. `R4-plugins.md`

```diff
-- [ ] รายการ plugin ที่ใช้ได้มาจาก node ของ connection นั้นจริง (`GET /` → plugins ที่โหลดอยู่บน server) รวม custom plugin
+- [ ] รายการ plugin มาจาก `GET /` → `plugins.available_on_server` ของ connection นั้น (ไม่ใช่ `enabled_in_cluster`)
+      รวม custom plugin · plugin ที่ไม่ได้โหลดบน node ไม่แสดง
+- [ ] custom plugin: คำอธิบายจาก `config/custom_plugins/<name>.yml` ถ้าไม่มี บอกชัดว่าไม่มี
+- [ ] เตือนเมื่อ schema ของ plugin เดียวกันต่างจาก env อื่นใน project เดียวกัน
```

### C6. `R5-project-understanding.md`

ตัดสินแล้ว: หน้า overview + request tracer จาก read-model + notes markdown ที่ `config/projects/<key>.md`
ใน repo Kongsole (แชร์ผ่าน git แก้ผ่าน PR)
```diff
-- [ ] คนใหม่ตอบได้ภายใน 5 นาทีว่า request ไปยัง path หนึ่งผ่าน route, service, plugin อะไรบ้าง
+- [ ] คนใหม่ใช้ request tracer (host + path + method) แล้วเห็น route, service และ plugin ตามลำดับที่ทำงาน
+      ภายใน 5 นาที ตามสคริปต์ทดสอบใน plan R5 (เจ้าของงานเป็นผู้ตรวจรับ)
```

### C7. `R6-traffic-dashboard.md`

ตัดสินแล้ว: ใช้ Prometheus plugin (มีอยู่แล้วทุก project) + Prometheus ขององค์กร (query PromQL) ทุก env
```diff
-- ใช้ข้อมูลจาก File Log plugin
-- ล้างข้อมูลเก่าอัตโนมัติ เพราะกังวลเรื่อง storage
+- ใช้ metric จาก Kong Prometheus plugin ผ่าน Prometheus ขององค์กร Kongsole ไม่เก็บ log หรือ metric เอง
-- [ ] raw log เก็บไม่เกิน N วัน ข้อมูลสรุปเก็บ M วัน ลบอัตโนมัติ ตั้งค่าได้ และแสดงพื้นที่ที่ใช้อยู่
-- [ ] ไม่เก็บ header, cookie, query หรือ body ที่อ่อนไหว ... กรองก่อนเขียนลงดิสก์ของ Kongsole และมี test
-- [ ] การเก็บ log ไม่ทำให้ latency ของ Kong เพิ่มอย่างมีนัยสำคัญ
+- [ ] Kongsole ไม่เขียน metric หรือ log ลงดิสก์ · token ของ Prometheus (ถ้ามี) ไม่ถูกคืนผ่าน API และไม่ถูก log
+- [ ] แต่ละ connection แสดง preflight: มี prometheus plugin ไหม, scope, `status_code_metrics` เปิดไหม
+      ถ้าไม่พร้อม บอกวิธีแก้ (แก้ plugin ผ่าน R4 → direct หรือ changeset)
```

### C8. `R7-export-config.md`

ผู้ใช้และสถานการณ์: export decK YAML ของ connection เพื่อนำไป promote ขึ้น env อื่นเอง
```diff
-Export config ทั้งหมดของ connection หรือ project และเลือก/แก้ template ก่อน export
+Export ด้วย `deck gateway dump --select-tag <ค่าที่ผู้ใช้กรอก>` ของ connection เดียว
-- [ ] เลือกขอบเขตได้: project, env, connection, ชนิด entity, tag
+- [ ] เลือก project/env (connection) และ select_tag อย่างน้อย 1 ค่า · ห้าม `kong-admin-path`
-- [ ] export ซ้ำจากข้อมูลเดิมได้ไฟล์เหมือนเดิมทุก byte
+- [ ] export ซ้ำจาก Kong ที่สถานะเดิมได้ไฟล์เหมือนเดิมทุก byte (ไม่มีเวลาใน body)
-- [ ] เลือกและแก้ template ได้ก่อน export
+- [ ] ไฟล์มี `_info.select_tags` และ header บอกว่าเป็น snapshot, ครอบทั้ง scope ของ tag,
+      และ env PR mode ต้องนำเข้าผ่าน PR ของ repo project ไม่ใช่ `deck gateway sync` ด้วยมือ
+- [ ] MCP `kong_export` ใช้ sanitizer เดียวกัน
```
ตัดสินแล้ว: ไม่มี template · export จาก direct env ได้ · ต้องแก้กฎข้อ 2 ของ CLAUDE.md ก่อน (§B)

### C9. `R8-pr-mode-changeset.md`

```diff
-- [ ] หลังเปิด PR แสดงลิงก์และสถานะของ PR
+- [ ] หลัง push แสดงลิงก์ branch (จาก `git_web_url` ของ project) และ PR body ให้คัดลอก
+      ผู้ใช้วาง URL ของ PR กลับมาได้ · สถานะจาก host API ยังไม่ทำจนกว่าเลือก git host
+- [ ] ตรวจ CiGate (admin path + delete threshold ของ project, default 3) ใน Kongsole ก่อน push
```
ตัดสินแล้ว: 1 changeset ต่อ 1 connection · ไม่มี changeset ใน direct · agent เพิ่มรายการได้ ส่งได้เฉพาะคน ·
ทุกการเขียน PR mode เข้า changeset · git host ยังไม่เลือก · threshold ยังไม่ตัดสิน (ใช้ 3)
