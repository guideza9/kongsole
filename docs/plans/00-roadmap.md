# 00 — Roadmap: R1–R8

> สถานะ: **รออนุมัติ plan (ปรับรอบ 2 แล้ว 2026-09-24)** — ห้ามสร้าง worktree ห้ามเริ่ม subagent ห้ามแก้โค้ด จนกว่าเจ้าของงานพิมพ์ "อนุมัติ plan"
> Worktree (ช่วงที่ 2): `.claude/worktrees/roadmap-r1-r8` (branch `feature/roadmap-r1-r8`) · branch ตั้งต้น: `feature/update_ui_format` @ `dc0ca74` (661668b + plan รอบ 2)

## สรุปหน้าเดียว

ทำ 9 ก้อนตามลำดับ **T0 → R3 → R1 → R8 → R2 → R4 → R5 → R7 → R6** ทีละก้อน หยุดรายงานเมื่อจบแต่ละก้อน

| ก้อน | ได้อะไร | ทำไมอยู่ตรงนี้ |
|---|---|---|
| **T0** ความปลอดภัยและเครื่องมือ | ปิด token หลุด, redactor อ่าน schema, catalog plugin ถูกต้อง, test ผ่านครบ, snapshot สำหรับ detect | เป็นการละเมิดกฎข้อ 4 ที่มีอยู่แล้ววันนี้ และทุก R ต้องมี baseline ที่ไม่มี test ล้ม |
| **R3** โครงสร้าง hint | `hints.en.yml`, helper/partial, การปิด hint, error 6 แบบ + ปัญหาเครือข่าย 4 ชนิด (`Kong::NetworkFailure`), retrofit หน้าที่มีอยู่ | ทุก R หลังจากนี้ต้องผ่านเกณฑ์ R3 จึงต้องมีที่ใส่ hint ก่อน |
| **R1** project/env | ตาราง `projects`/`project_envs`, apply_mode ไม่กำหนด = ห้ามเขียน, switcher, MCP `project/env`, `network_note` ต่อ project + สถานะ `unreachable` | ฐานของ R2, R5, R6, R7, R8 |
| **R8** changeset | สะสม plan PR mode → preview → push branch ครั้งเดียว | R2/R4 ต้องเขียนลง PR mode ผ่าน changeset |
| **R2** service/route | ฟอร์มทำมือ, route overlap, ปุ่มตาม access | ต้องมี R1 + R8 + R3 |
| **R4** plugins | catalog + ฟอร์มจาก schema + secret field + schema cache | ต้องมี T0 (redactor) + R8 |
| **R5** project overview | overview + request tracer + notes ใน git | ต้องมี R1 และ read-model ครบ (R4 ทำให้ plugin chain ถูก) |
| **R7** export | `deck gateway dump --select-tag` + sanitizer + `kong_export` | ต้องมี R1 และกฎข้อ 2 ของ CLAUDE.md ที่แก้แล้วใน T0.0 (อนุมัติรอบ 2) |
| **R6** dashboard | query Prometheus ขององค์กร (ไม่ส่ง credential), โหลดข้อมูลแยกต่อ env, บอกปัญหาเครือข่ายของ project + preflight `status_code_metrics` | ต้องมี R1; การเปิด `status_code_metrics` ใน env PR ต้องใช้ R4+R8 |

### กราฟการพึ่งพา

```
T0 ──► R3 ──► R1 ──► R8 ──► R2
                │      └──► R4 ──► R5
                ├──────────────────► R7   (gate: CLAUDE.md rule 2 — แก้ใน T0.0)
                └──────────────────► R6   (preflight fix ใช้ R4+R8)
```

## Baseline (วัดเมื่อ 2026-09-24 บน `661668b`)

| สิ่งที่วัด | ผล | หมายเหตุ |
|---|---|---|
| RSpec | **843 examples, 49 failures** (25.9s) | ทั้ง 49 = `Missing Active Record encryption credential` ใน `api/v1/change_plans_spec` (38), `api/v1/certificates_spec` (9), `kong_connection_spec` (1), `connection_login_spec` (1). รันด้วย `DATABASE_URL=postgres://kongsole:kongsole@localhost:5433/kong_integration_test` |
| MCP vitest | 25 pass / 1 fail | fail = `config.test.ts` เพราะ token ฝังใน `mcp/src/config.ts:13` |
| `npx impeccable detect app/views app/assets/tailwind/application.css` | 0 findings | **ไม่มีความหมาย** — detect ไม่อ่าน `.erb`; T0.6 ทำ snapshot HTML แล้ววัด baseline ใหม่ |
| detect บน snapshot (T0.6, 2026-09-24) | **44 findings** บน 31 หน้า (warning 39, advisory 5) · `cramped-padding` 39, `gpt-thin-border-wide-shadow` 3, `em-dash-overuse` 2 | ต่อหน้า: change-plan-direct/pr/delete 6 ต่อหน้า · connections-new 4 · entity-show 4 · entities-new-certificate 3 · connections-index 2 · entities-new-ca_certificate 2 · plugins-new-config 2 · tokens-new 2 · audit-events-index, change-plans-index, entities-new-sni/target/upstream, health, login 1 ต่อหน้า · entities-index ทั้ง 11 tab, certificates-expiring, plugins-new-catalog, tokens-index 0 · สร้างใหม่: `UI_SNAPSHOTS=1 bundle exec rspec spec/requests/ui_snapshots_spec.rb` แล้ว `npx impeccable detect --json tmp/ui-snapshots` |
| `/impeccable critique app/views` (degraded, source-only, เลนส์มือใหม่) | 25/40 | H2=2, H6=2, H7=2, H10=1 (รอบก่อน 28/40 เลนส์ต่างกัน) |
| `/impeccable audit app/views` | 15/20 | P1: ไม่มี hint infra, JSON-only forms; P2: Google Fonts, detect ไม่สแกน erb |
| Kong ในเครื่อง | 3.7.1, 2 node | `enabled_in_cluster = [basic-auth, acl]`, `available_on_server` = 43 plugins; aws-lambda `aws_key`/`aws_secret`/`aws_assume_role_arn` เป็น `encrypted+referenceable` แต่ไม่อยู่ใน redactor; prometheus `status_code_metrics` default **false** |
| decK | **ติดตั้งแล้ว 2026-09-24:** v1.66.1 ที่ `%LOCALAPPDATA%\Programs\deck\deck.exe` (SHA-256 ตรงกับ `checksums.txt` ของ release, เพิ่มเข้า PATH ของ user) · `deck gateway ping` ผ่าน route ro → Kong 3.7.1 | terminal / `bin/dev` ที่เปิดไว้ก่อนติดตั้งต้องเปิดใหม่ หรือตั้ง `DECK_BIN` |

## Migrations ทั้งหมด (reversible + rollback)

| # | ก้อน | Migration | `down` | Rollback สำหรับ CAB |
|---|---|---|---|---|
| 1 | R1 | `CreateProjects` (รวม `network_note`, `delete_threshold`) | drop table | ไม่มีข้อมูลอื่นพึ่ง ก่อน #3 ถอย |
| 2 | R1 | `CreateProjectEnvs` | drop table | เหมือน #1 |
| 3 | R1 | `AddProjectEnvToKongConnections` (+ backfill ใส่ project `default`, env = ชื่อ connection เดิม) | ลบ column `project_env_id` (ข้อมูล project/env หาย, connection เดิมยังอยู่ครบ credential ไม่แตะ) | `bin/rails db:rollback STEP=3` หลังถอดโค้ด R1; `connections.yml` รูปแบบเดิมยังโหลดได้ · migrate กลับถูกปฏิเสธ (`ConflictingRepos`) ถ้า PR connection ชี้ git repo ต่างกัน — ไม่มีอะไรเปลี่ยน: ใน `bin/rails console` ใช้ `KongConnection.where(name: [...]).update_all(git_repo: "<repo ที่ถูก>")` หรือลบ connection ที่ไม่ใช้ แล้ว `bin/rails db:migrate` อีกครั้ง (R1.16) |
| 4 | R1 | `MakeKongConnectionApplyModeNullable` (drop default `direct`, allow null) | **ปฏิเสธ** ถ้ามีแถว `apply_mode IS NULL` พร้อมรายชื่อ; ถ้าไม่มี คืน default+not null | ก่อน rollback ต้องกำหนด apply_mode ให้ทุก connection ที่ยังว่าง (ห้ามเดาเป็น direct — นั่นคือบั๊กที่ R1 ปิด) |
| 5 | R8 | `CreateChangesets` (`20260925110000`; partial unique index: open ได้ 1 ต่อ connection) | drop table | ต้อง rollback #6 ก่อน (`bin/rails db:rollback STEP=2` ถอยทั้งคู่ตามลำดับ) · ประวัติ changeset หายทั้งหมด: `branch`, `commit_sha`, `pr_body`, `pr_url`, `gate_reasons`, `deck_diff` — branch ที่ push แล้วยังอยู่ใน git และ audit event ของแต่ละ plan ยังอยู่ (context มี `changeset_id` เป็นตัวเลขเฉยๆ) |
| 6 | R8 | `AddChangesetToChangePlans` (`20260925110100`; `changeset_id`, `position`, `provisional_kong_id`, `replaces_plan_id`) | ลบ 4 column; plan PR ที่ค้างใน changeset กลายเป็น plan เดี่ยวซึ่ง `expires_at` ผ่านไปแล้ว จึงหมดอายุทันที (ปลอดภัย: ไม่มีอะไรถูก push) | ก่อน rollback: ถอดโค้ด R8 ออกก่อน (โค้ดก่อน R8 ยัง apply plan PR เดี่ยวได้) · ปิด changeset ที่ `open` ด้วย Abandon หรือยอมให้รายการหมดอายุ · `bin/rails db:rollback STEP=2` · ตรวจ `ChangePlan.where(apply_mode: "pr", status: "pending")` = หมดอายุทั้งหมด |
| 7 | R4 | `CreateKongSchemas` (schema cache) | drop table | cache ล้วน สร้างใหม่ได้ |
| 8 | R6 | `AddPrometheusUrlToProjects` | ลบ column | ไม่มีข้อมูลอื่นพึ่ง |
| 9 | R6 | `AddPrometheusSelectorToProjectEnvs` | ลบ column | ไม่มีข้อมูลอื่นพึ่ง |

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

## การตัดสินใจรอบ 2 (2026-09-24)

| # | เรื่อง | คำตอบ | ผลใน plan |
|---|---|---|---|
| 1 | CLAUDE.md กฎข้อ 2 ขัดกับ export ด้วย `deck gateway dump` | แก้ตามข้อความที่เสนอ | T0.0 แก้ `CLAUDE.md` ตาม `design-amendments.md` §B · R7.0 เหลือแค่ตรวจว่าแก้แล้ว |
| 2 | connection จาก `connections.yml` แก้ใน UI ไม่ได้ทั้งหมด | ใช่ | R1.5 (403), R1.9 (อ่านอย่างเดียว) |
| 3 | R3 ย้ายเข้า locale เฉพาะ hint | ใช่ | R3 |
| 4 | R5/R6 ไม่ต้อง login | ไม่ต้อง login **แต่ต้องจัดการ error เพราะแต่ละ project อยู่คนละ network** | ดู "เครือข่ายของแต่ละ project" ข้างล่าง |
| 5 | Prometheus ต้องมี credential ไหม | ไม่ส่ง credential ตอนนี้ — ถ้าเจอ 401/403 ค่อยเพิ่ม | R6: `AuthRequired` + คำอธิบาย `prometheus_auth_required`, ไม่มี token column/ฟอร์ม · **งานต่อที่รอ:** "Prometheus credential" เปิดเมื่อเจอ 401/403 จริง (หยุดถามก่อนทำ) |
| 6 | threshold การลบ | 3 | `projects.delete_threshold` default 3 |
| 7 | แก้ `docs/requirements/` และ `docker-compose.yml` | ได้ | T0.0, R6.0 |

### เครือข่ายของแต่ละ project (มาจากข้อ 4)

ปัญหาที่พบในโค้ดตอนนี้: `Kong::Client#request` (`app/services/kong/client.rb:83-84`) แปลง DNS / refused / timeout / TLS
ทั้งหมดเป็น `UpstreamUnavailable` ซึ่งเป็น class เดียวกับ 502/503 จาก loopback — ผู้ใช้ที่ไม่ได้ต่อ network ของ project
จะเห็นว่า "Admin API ล่ม" ซึ่งผิด การแก้ที่อยู่ใน plan:

| ชิ้น | task | ทำอะไร |
|---|---|---|
| `Kong::NetworkFailure` | R3.2 | จำแนกเป็น `:dns / :refused / :timeout / :tls` จาก exception (Faraday) และจากข้อความของ decK/git (+ `:auth` ของ git) |
| `Kong::Client::NetworkUnreachable` | R3.2 | subclass ของ `UpstreamUnavailable` (rescue เดิมยังจับได้) มี `kind` |
| `hints.errors.network_*` | R3.2, R3.5 | ข้อความ 4 ชนิด บอกว่า "เครื่องนี้อาจไม่ได้อยู่ใน network ของ project" |
| `projects.network_note` | R1.1, R1.11 | เช่น "Reachable from the NONPROD VPN only" จาก `connections.yml` หรือ UI; ต่อท้าย error เครือข่ายทุกที่ |
| สถานะ `unreachable` | R1.11 | login ที่เข้าไม่ถึงบันทึกเป็น `unreachable` ไม่ใช่ `unavailable`; หน้า Connections / overview แสดง "Unreachable from this machine" |
| R5 overview/tracer | R5 | ไม่มี network call เลย ใช้ได้เสมอ; แสดงสถานะจาก login ล่าสุด + network note |
| R6 dashboard | R6.2, R6.5 | หน้า shell ไม่เรียก Prometheus; ข้อมูลโหลดใน Turbo Frame แบบ lazy ต่อ env; timeout 3s/10s; error แสดงในกรอบพร้อมชนิด + network note + "Try again" ไม่ 500 |
| R7 export | R7.1 | `DeckCli::Unreachable` (kind จาก stderr ของ decK) → คำอธิบายเครือข่าย |
| R8 changeset | R8.4 | `GitClient::Unreachable` / `AuthFailed` → preview/submit แสดงคำอธิบาย รายการใน changeset ยังอยู่ครบ |

### งานต่อที่รอ (จากรีวิวปิด T0, ตัดสิน 2026-09-25)

- **Secret ของ plugin ในเส้นทางเขียน** — create/update plugin ยังเก็บค่าลับ plaintext ใน `change_plans.after` / `diff` /
  `deck_diff`, `audit_events.diff` และคืนผ่าน API (MCP) · rake `kong:redact_stored_plugin_secrets` ล้างได้เฉพาะของที่มีอยู่แล้ว ·
  เจ้าของงานเลือก "เปิดเป็น task แยกทีหลัง" (ทางเลือก: redact ตอนบันทึก audit + หลัง apply / เข้ารหัส column ระหว่าง pending) — หยุดถามก่อนทำ

### งานต่อที่รอ (จากตรวจ R1.12 บนเครื่อง compose, ตัดสิน 2026-09-25)

- **connection `stored` login ใน development ไม่ได้บนเครื่องที่ไม่มี `config/master.key`** — ได้ 500
  `ActiveRecord::Encryption::Errors::Configuration` (T0.4 ตั้งกุญแจให้เฉพาะ test) · ทางเลือก: วาง `master.key` จริง / ตั้งกุญแจ dev แยก /
  แสดงข้อความแทน 500 · เจ้าของงานเลือก "จดไว้ก่อน ยังไม่ทำ" — หยุดถามก่อนทำ
- **หน้า plan ขัดกันเองเมื่อ env เขียนไม่ได้แล้ว** (ข้อสังเกตของ R1.17) — plan ที่เสนอไว้ตอน env ยังเขียนได้ แสดงการ์ด
  "Direct apply → live write to Kong" และ "Guardrails: All clear" เหนือ notice "Nothing can be written" (server ปฏิเสธถูกต้อง) ·
  ทางแก้ที่น่าจะเล็กที่สุด: `ChangePlansController#show` ใช้ `write_block_reason` ตอนคำนวณการ์ด guardrail (backend) · ยังไม่ตัดสิน — หยุดถามก่อนทำ

## ข้อความที่จะแก้ในไฟล์ requirement

อยู่ใน `docs/plans/design-amendments.md` §C (อนุมัติแล้ว — แก้ไฟล์จริงเป็น task แรกของช่วงที่ 2: `T0.0` พร้อม `CLAUDE.md` §B) · §A (DESIGN.md) เป็นร่างให้ทีมแก้เอง

## ความเสี่ยง

| ระดับ | ความเสี่ยง | รับมือ |
|---|---|---|
| สูงสุด | R8 changeset render ผิด → PR ลบของ → CI sync ลบจริง (รวม admin path) | `CiGate` รันก่อน push (ไม่ใช่แค่ใน CI), admin-path check ต่อ plan, round-trip byte-exact, preview diff บังคับก่อน submit |
| สูงสุด | R7 export ถูกนำไป `deck gateway sync` แล้วลบของใน env ปลายทาง | export ทั้ง scope ของ tag เท่านั้น, `_info.select_tags` เสมอ, header เตือน, ปฏิเสธ tag `kong-admin-path`, sanitizer ตัด admin path ซ้ำอีกชั้น |
| สูง | R7 `deck gateway dump` ได้ credential/private key/secret ของ plugin ออกมาจาก Kong | dump ไม่เขียนลงดิสก์ (`-o -` → memory), sanitizer ตัดก่อนแสดง/ดาวน์โหลด, test ด้วย fixture ที่มี secret ทุกชนิด |
| สูง | R1 เปลี่ยนที่มาของ rank → guardrail เงียบ | ชื่อ dev/sit/uat/prod ถูกบังคับ rank เดิม; ชื่ออื่นต้องเลือก rank (ไม่มี default); apply_mode ว่าง = ห้ามเขียนทุกเส้นทาง (planner, applier, API) |
| สูง | R6 ข้อมูลว่างเพราะ `status_code_metrics=false` (default ของ Kong 3.7) | preflight ต่อ connection บอกชัดและลิงก์ไปแก้ plugin (ผ่าน R4/R8) |
| สูง | แต่ละ project อยู่คนละ network → ผู้ใช้เห็น "Kong ล่ม" ทั้งที่แค่ยังไม่ได้ต่อ VPN / หน้าเว็บค้างรอ timeout | `NetworkFailure` + `NetworkUnreachable` แยกชนิด, `network_note` ต่อ project, สถานะ `unreachable`, R6 โหลดแบบ lazy ต่อ env พร้อม timeout 3s/10s |
| กลาง | Prometheus ขององค์กรต้องการ credential (ยังไม่รองรับ) | ตรวจพบเป็น `AuthRequired` พร้อมคำอธิบาย ไม่ใช่ "unreachable" · เปิดงานต่อเมื่อเจอจริง |
| กลาง | R8 route ใต้ service ที่สร้างใน changeset เดียวกัน (ยังไม่มี kong id) | `provisional_kong_id` + resolver ที่อ่าน changeset |
| กลาง | Repo ของแต่ละ project มี base YAML / หลายไฟล์ ("ทุกอย่างในกฎของ decK") | Kongsole เขียนแค่ `git_path` ของ env (รูปแบบของตัวเอง) และส่งไฟล์อื่นเป็น `deck_extra_paths` แบบอ่านอย่างเดียวให้ validate/diff |
| กลาง | detect ไม่อ่าน erb | T0.6 snapshot HTML จาก request spec แล้วรัน detect บน snapshot + เปิด browser จริง |
| กลาง | decK ไม่อยู่ในเครื่องนี้ | ติดตั้งก่อน R8/R7 verification |
| ต่ำ | Route matcher ของ R5 เป็นการประมาณ router ของ Kong | บอกใน UI ว่า "approximation of Kong's traditional router"; regex ใช้ Ruby Regexp |

## ความคืบหน้า

- [x] T0 — `docs/plans/T0-security-and-tooling.md` (ปิด 2026-09-25: rspec 889/0, vitest 28/28, PAT revoke แล้ว — เจ้าของงานยืนยัน)
- [ ] R3 — `docs/plans/R3-onboarding-hints.md` (R3.1–R3.6 เสร็จ · ตรวจเกณฑ์ 2026-09-25: rspec 951/0, ต่อมา 952/0, detect ไม่เพิ่มจาก baseline · ข้อค้าง 2 ข้อแก้แล้ว · เหลือ R3.7 ซึ่งทำหลัง R2)
- [x] R1 — `docs/plans/R1-multi-project-env.md` (ปิด 2026-09-25: R1.1–R1.21 เสร็จ, rspec 1085/0, vitest 30/30, detect 60 (R1.17 = 62), migration 4 ตัว up/down บนสำเนา DB — เจ้าของงานยืนยัน)
- [ ] R8 — `docs/plans/R8-pr-mode-changeset.md` (R8.1–R8.10 + final review เสร็จ 2026-09-25: rspec 1174/0, vitest 31/31 · รอเจ้าของงาน: ตัดสิน "แก้รายการ" (#5) แล้วยืนยันปิด)
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
