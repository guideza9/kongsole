# 00 — Roadmap: R1–R8

> สถานะ: **รออนุมัติ plan** — ห้ามสร้าง worktree ห้ามเริ่ม subagent ห้ามแก้โค้ด จนกว่าเจ้าของงานพิมพ์ "อนุมัติ plan"
> Worktree (ช่วงที่ 2): _บันทึก path ที่นี่เมื่อสร้าง_ · branch ตั้งต้น: `feature/update_ui_format` @ `661668b`

## สรุปหน้าเดียว

ทำ 9 ก้อนตามลำดับ **T0 → R3 → R1 → R8 → R2 → R4 → R5 → R7 → R6** ทีละก้อน หยุดรายงานเมื่อจบแต่ละก้อน

| ก้อน | ได้อะไร | ทำไมอยู่ตรงนี้ |
|---|---|---|
| **T0** ความปลอดภัยและเครื่องมือ | ปิด token หลุด, redactor อ่าน schema, catalog plugin ถูกต้อง, test ผ่านครบ, snapshot สำหรับ detect | เป็นการละเมิดกฎข้อ 4 ที่มีอยู่แล้ววันนี้ และทุก R ต้องมี baseline ที่ไม่มี test ล้ม |
| **R3** โครงสร้าง hint | `hints.en.yml`, helper/partial, การปิด hint, error 6 แบบ, retrofit หน้าที่มีอยู่ | ทุก R หลังจากนี้ต้องผ่านเกณฑ์ R3 จึงต้องมีที่ใส่ hint ก่อน |
| **R1** project/env | ตาราง `projects`/`project_envs`, apply_mode ไม่กำหนด = ห้ามเขียน, switcher, MCP `project/env` | ฐานของ R2, R5, R6, R7, R8 |
| **R8** changeset | สะสม plan PR mode → preview → push branch ครั้งเดียว | R2/R4 ต้องเขียนลง PR mode ผ่าน changeset |
| **R2** service/route | ฟอร์มทำมือ, route overlap, ปุ่มตาม access | ต้องมี R1 + R8 + R3 |
| **R4** plugins | catalog + ฟอร์มจาก schema + secret field + schema cache | ต้องมี T0 (redactor) + R8 |
| **R5** project overview | overview + request tracer + notes ใน git | ต้องมี R1 และ read-model ครบ (R4 ทำให้ plugin chain ถูก) |
| **R7** export | `deck gateway dump --select-tag` + sanitizer + `kong_export` | ต้องมี R1 และ **รอแก้กฎข้อ 2 ของ CLAUDE.md** (ดู "ต้องอนุมัติเพิ่ม") |
| **R6** dashboard | query Prometheus ขององค์กร + preflight `status_code_metrics` | ต้องมี R1; การเปิด `status_code_metrics` ใน env PR ต้องใช้ R4+R8 |

### กราฟการพึ่งพา

```
T0 ──► R3 ──► R1 ──► R8 ──► R2
                │      └──► R4 ──► R5
                ├──────────────────► R7   (gate: CLAUDE.md rule 2 amendment)
                └──────────────────► R6   (preflight fix ใช้ R4+R8)
```

## Baseline (วัดเมื่อ 2026-09-24 บน `661668b`)

| สิ่งที่วัด | ผล | หมายเหตุ |
|---|---|---|
| RSpec | **843 examples, 49 failures** (25.9s) | ทั้ง 49 = `Missing Active Record encryption credential` ใน `api/v1/change_plans_spec` (38), `api/v1/certificates_spec` (9), `kong_connection_spec` (1), `connection_login_spec` (1). รันด้วย `DATABASE_URL=postgres://kongsole:kongsole@localhost:5433/kong_integration_test` |
| MCP vitest | 25 pass / 1 fail | fail = `config.test.ts` เพราะ token ฝังใน `mcp/src/config.ts:13` |
| `npx impeccable detect app/views app/assets/tailwind/application.css` | 0 findings | **ไม่มีความหมาย** — detect ไม่อ่าน `.erb`; T0.6 ทำ snapshot HTML แล้ววัด baseline ใหม่ |
| `/impeccable critique app/views` (degraded, source-only, เลนส์มือใหม่) | 25/40 | H2=2, H6=2, H7=2, H10=1 (รอบก่อน 28/40 เลนส์ต่างกัน) |
| `/impeccable audit app/views` | 15/20 | P1: ไม่มี hint infra, JSON-only forms; P2: Google Fonts, detect ไม่สแกน erb |
| Kong ในเครื่อง | 3.7.1, 2 node | `enabled_in_cluster = [basic-auth, acl]`, `available_on_server` = 43 plugins; aws-lambda `aws_key`/`aws_secret`/`aws_assume_role_arn` เป็น `encrypted+referenceable` แต่ไม่อยู่ใน redactor; prometheus `status_code_metrics` default **false** |
| decK | ไม่มีบน PATH ของเครื่องนี้ | R7/R8 verification ต้องติดตั้ง decK 1.51.1 หรือ 1.66.1 (หรือตั้ง `DECK_BIN`) |

## Migrations ทั้งหมด (reversible + rollback)

| # | ก้อน | Migration | `down` | Rollback สำหรับ CAB |
|---|---|---|---|---|
| 1 | R1 | `CreateProjects` | drop table | ไม่มีข้อมูลอื่นพึ่ง ก่อน #3 ถอย |
| 2 | R1 | `CreateProjectEnvs` | drop table | เหมือน #1 |
| 3 | R1 | `AddProjectEnvToKongConnections` (+ backfill ใส่ project `default`, env = ชื่อ connection เดิม) | ลบ column `project_env_id` (ข้อมูล project/env หาย, connection เดิมยังอยู่ครบ credential ไม่แตะ) | `bin/rails db:rollback STEP=3` หลังถอดโค้ด R1; `connections.yml` รูปแบบเดิมยังโหลดได้ |
| 4 | R1 | `MakeKongConnectionApplyModeNullable` (drop default `direct`, allow null) | **ปฏิเสธ** ถ้ามีแถว `apply_mode IS NULL` พร้อมรายชื่อ; ถ้าไม่มี คืน default+not null | ก่อน rollback ต้องกำหนด apply_mode ให้ทุก connection ที่ยังว่าง (ห้ามเดาเป็น direct — นั่นคือบั๊กที่ R1 ปิด) |
| 5 | R8 | `CreateChangesets` | drop table | ต้อง rollback #6 ก่อน |
| 6 | R8 | `AddChangesetToChangePlans` (+ `provisional_kong_id`) | ลบ column; plan PR ที่ค้างใน changeset กลายเป็น plan เดี่ยวที่หมดอายุแล้ว | ปิด changeset ที่ `open` ทั้งหมดก่อน (หรือยอมให้หาย — ไม่มีอะไรถูก push) |
| 7 | R4 | `CreateKongSchemas` (schema cache) | drop table | cache ล้วน สร้างใหม่ได้ |
| 8 | R6 | `AddPrometheusToProjects` (`prometheus_url`, `prometheus_token` encrypted) + `AddPrometheusSelectorToProjectEnvs` | ลบ columns | ไม่มีข้อมูลอื่นพึ่ง |

R2, R3, R5, R7, T0 ไม่มี migration

## การตัดสินใจจากคำตอบของเจ้าของงาน

| # | คำตอบ | ผลใน plan |
|---|---|---|
| Q1 | revoke PAT เอง + แก้ไฟล์ ไม่ rewrite ประวัติ | T0.1 |
| Q2 | แก้ redactor ก่อนทุกอย่าง | T0.2 |
| Q3 | env `pr` กำหนดได้เฉพาะ `connections.yml`; env `direct` สร้าง/แก้ใน UI ได้ | R1: `source` = `registry`/`local`; UI สร้างได้เฉพาะ direct/ยังไม่กำหนด; UI ไม่มีทางตั้งหรือถอด `pr` |
| Q4 + F1 | ชื่อ env ตั้งเอง (pt=perftest, ps=preprod); ชื่อที่ไม่ใช่ dev/sit/uat/prod แสดงเป็น "other" และผู้ใช้**ต้องเลือก rank 0–3 ไม่มีค่า default** | R1: `ProjectEnv` validation |
| Q5 | 1 env = 1 node = 1 connection | R1: unique `project_env_id` บน connection |
| Q6 | repo แยกต่อ project | R1: git config ระดับ project (`git_repo`, `git_branch`, `git_web_url`); `git_path` ระดับ env |
| Q7 | สลับ env = login ใหม่ทุกครั้ง | R1: switcher ลิงก์ไปหน้า login |
| Q8 | MCP อ้าง `project/env` | R1: `KongConnection#qualified_name` |
| Q9 | ไม่มี git host API รอบนี้ — push branch + ลิงก์จาก `git_web_url` | R8: PR body ให้คัดลอก + ช่องให้วาง URL ของ PR |
| Q10 | 1 changeset ต่อ 1 connection | R8 |
| Q11 | threshold ยังไม่ตัดสิน | R8: ใช้ 3 (ค่าของ `CiGate`), ตั้งค่าต่อ project ได้ — **ค้างให้ตัดสิน** |
| Q12 | ไม่มี changeset ใน direct mode | R8 |
| Q13 | agent เพิ่มเข้า changeset ได้ ส่ง PR ได้เฉพาะคน | R8: `kong_apply` บน plan ใน changeset → 403 |
| Q14 | ทุกการเขียน PR mode เข้า changeset | R8: plan เดี่ยว PR mode ถูกปฏิเสธที่ applier |
| Q15–16 | UI ภาษาอังกฤษทั้งหมด (Google Fonts ใช้ได้) | R3: hint ภาษาอังกฤษ; ไม่ต้องทำฟอนต์ไทย |
| Q17 | AI เขียน hint, ที่ไม่มั่นใจติด `To Edit` | R3: `bin/rails hints:todo` แสดงรายการให้ตรวจ |
| Q18 | ฟอร์มแบบผสม | R2 ฟอร์มทำมือ, R4 ฟอร์มจาก schema, type อื่นใช้ reference panel |
| Q19 | custom plugin description จาก metadata ใน repo; ไม่แสดง plugin ที่ไม่ได้โหลด; เตือน schema ต่างเวอร์ชัน | R4 |
| Q20 | ไม่มีค่าตั้งต้นต่อ project, ไม่มี promote flow | R2 |
| Q21 | overlap: host ทับ + path ซ้ำ/prefix; regex = ตรวจไม่ได้ | R2: `Kong::RouteOverlap` |
| Q22 | overview จาก read-model + notes markdown ใน repo Kongsole | R5 |
| Q23 + F4 | Prometheus plugin; องค์กรมี Prometheus; ทุก env; ทุก project มี plugin แล้ว | R6: query PromQL; ไม่เก็บข้อมูลเอง |
| Q24 + F2 + F3 | export = `deck gateway dump --select-tag <ค่าที่ผู้ใช้กรอก>`; export จาก direct ได้; `kong_export` อยู่ใน scope; ไม่มี template | R7 |
| Q25 | AI ร่างแก้ DESIGN.md ให้ทีมแก้เอง | `docs/plans/design-amendments.md` |
| Q26–27 | Docker เปิดแล้ว; ลำดับตามที่เสนอ | ตารางบนสุด |

## ต้องอนุมัติเพิ่มก่อนเริ่ม (เรื่องที่ plan ตีความเอง)

1. **CLAUDE.md กฎข้อ 2 ขัดกับ F2 ตามตัวอักษร** — "Render decK YAML จาก git ไม่ใช่จาก `deck dump`". R7 ใช้ `deck gateway dump` ตามที่เจ้าของงานตัดสิน plan จึงเสนอให้แก้กฎให้ชัดว่าหมายถึง "YAML ที่ Kongsole เขียนลง git ของ env PR" และเพิ่มข้อยกเว้น export ที่ต้องผ่าน `Kong::ExportSanitizer` เสมอ (ข้อความใน `design-amendments.md` §B). **R7 จะไม่เริ่มจนกว่ากฎถูกแก้**
2. **connection ที่มาจาก `connections.yml` (registry) แก้ใน UI ไม่ได้ทั้งหมด** รวมถึง env direct ที่อยู่ในไฟล์ — เพราะ `kong:load_connections` รอบถัดไปจะเขียนทับ. env direct ที่สร้างใน UI แก้ได้เต็มที่และมีป้าย "Local only"
3. **R3 ย้ายเข้า locale เฉพาะ hint** (คำอธิบาย field, ตัวอย่าง, empty state, คำอธิบายผลกระทบ, error) ไม่ย้าย label/ปุ่มทุกตัว — ข้อเสนอเดิมใน brainstorming ที่ให้ย้ายข้อความ UI ทั้งหมดถูกถอนเพื่อคุม scope
4. **Prometheus ขององค์กรต้องมี auth ไหม** — plan รองรับ bearer token แบบ optional เก็บเข้ารหัสใน DB เครื่องตัวเอง ไม่คืนผ่าน API ใดๆ (เหมือน Kong credential)
5. **Threshold การลบ (Q11)** — ใช้ 3 ไปก่อน
6. **หน้า R5 (overview/tracer) และ R6 (dashboard) เปิดได้โดยไม่ต้อง login** — อ่านแค่ DB ในเครื่อง (ผ่าน redactor แล้ว) และ Prometheus ไม่เรียก Kong ถ้าต้องการให้ login ก่อน บอกได้ (เปลี่ยนแค่ `before_action` ใน 3 controller)
7. **R6.0 แก้ `docker-compose.yml` + `docker/kong/bootstrap.sh`** เพื่อเพิ่ม Prometheus และ plugin prometheus (`status_code_metrics: true`) ใน stack ของเครื่อง — ใช้ทดสอบเท่านั้น (กฎข้อ 7)
8. **T0 เป็นก้อนงานที่เพิ่มมาจากคำตอบ Q1–Q2** (ไม่อยู่ใน R1–R8) และ T0.0 แก้ไฟล์ `docs/requirements/` ตาม §C ของ `design-amendments.md`

## ข้อความที่จะแก้ในไฟล์ requirement

อยู่ใน `docs/plans/design-amendments.md` §C (แก้ไฟล์จริงเป็น task แรกของช่วงที่ 2: `T0.0`)

## ความเสี่ยง

| ระดับ | ความเสี่ยง | รับมือ |
|---|---|---|
| สูงสุด | R8 changeset render ผิด → PR ลบของ → CI sync ลบจริง (รวม admin path) | `CiGate` รันก่อน push (ไม่ใช่แค่ใน CI), admin-path check ต่อ plan, round-trip byte-exact, preview diff บังคับก่อน submit |
| สูงสุด | R7 export ถูกนำไป `deck gateway sync` แล้วลบของใน env ปลายทาง | export ทั้ง scope ของ tag เท่านั้น, `_info.select_tags` เสมอ, header เตือน, ปฏิเสธ tag `kong-admin-path`, sanitizer ตัด admin path ซ้ำอีกชั้น |
| สูง | R7 `deck gateway dump` ได้ credential/private key/secret ของ plugin ออกมาจาก Kong | dump ไม่เขียนลงดิสก์ (`-o -` → memory), sanitizer ตัดก่อนแสดง/ดาวน์โหลด, test ด้วย fixture ที่มี secret ทุกชนิด |
| สูง | R1 เปลี่ยนที่มาของ rank → guardrail เงียบ | ชื่อ dev/sit/uat/prod ถูกบังคับ rank เดิม; ชื่ออื่นต้องเลือก rank (ไม่มี default); apply_mode ว่าง = ห้ามเขียนทุกเส้นทาง (planner, applier, API) |
| สูง | R6 ข้อมูลว่างเพราะ `status_code_metrics=false` (default ของ Kong 3.7) | preflight ต่อ connection บอกชัดและลิงก์ไปแก้ plugin (ผ่าน R4/R8) |
| กลาง | R8 route ใต้ service ที่สร้างใน changeset เดียวกัน (ยังไม่มี kong id) | `provisional_kong_id` + resolver ที่อ่าน changeset |
| กลาง | Repo ของแต่ละ project มี base YAML / หลายไฟล์ ("ทุกอย่างในกฎของ decK") | Kongsole เขียนแค่ `git_path` ของ env (รูปแบบของตัวเอง) และส่งไฟล์อื่นเป็น `deck_extra_paths` แบบอ่านอย่างเดียวให้ validate/diff |
| กลาง | detect ไม่อ่าน erb | T0.6 snapshot HTML จาก request spec แล้วรัน detect บน snapshot + เปิด browser จริง |
| กลาง | decK ไม่อยู่ในเครื่องนี้ | ติดตั้งก่อน R8/R7 verification |
| ต่ำ | Route matcher ของ R5 เป็นการประมาณ router ของ Kong | บอกใน UI ว่า "approximation of Kong's traditional router"; regex ใช้ Ruby Regexp |

## ความคืบหน้า

- [ ] T0 — `docs/plans/T0-security-and-tooling.md`
- [ ] R3 — `docs/plans/R3-onboarding-hints.md`
- [ ] R1 — `docs/plans/R1-multi-project-env.md`
- [ ] R8 — `docs/plans/R8-pr-mode-changeset.md`
- [ ] R2 — `docs/plans/R2-create-service-route.md`
- [ ] R4 — `docs/plans/R4-plugins.md`
- [ ] R5 — `docs/plans/R5-project-understanding.md`
- [ ] R7 — `docs/plans/R7-export-config.md`
- [ ] R6 — `docs/plans/R6-traffic-dashboard.md`

## กติกาการทำงานในช่วงที่ 2 (ย้ำจาก kickoff)

- ทุก task: ชั้นเดียว (UI หรือ backend), แก้เฉพาะไฟล์ที่ task ระบุ, commit ทีละ task: `<type>(<task-id>): …` แล้วติ๊ก checkbox ใน plan
- Backend: เขียน test ก่อน (RED) → ผ่าน (GREEN) → refactor
- UI: ใช้คำสั่ง `/impeccable` ที่ระบุ ห้ามแตะ controller/model/migration/service
- plan ผิดหรือขาด task → หยุดถาม ห้ามแก้ plan เอง
- จบแต่ละก้อน: รายงานผล test, detect เทียบ baseline, ภาพหน้าจอ (390px + 1280px), ยืนยันไม่มี credential หลุด (`log_filtering_spec` + grep log หา `Basic `)
- Test command มาตรฐานหลัง T0.4: `bundle exec rspec` (ไม่ต้องตั้ง `DATABASE_URL` อีก)
- ทดสอบกับ compose ในเครื่องหรือ env ที่ `rank = 0` เท่านั้น
