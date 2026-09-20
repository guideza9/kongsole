# Kong CE Control Plane — Solution Design

เครื่องมือจัดการ Kong Community Edition ที่มีทั้ง UI สำหรับคน และ MCP server สำหรับ Claude Code
โดยใช้ backend, validation และ audit trail ชุดเดียวกัน

**สถานะ: รอ verify ก่อนเริ่ม M0** · rev 4, 2026-08-28
(เพิ่มการรับมือกับ Admin API ที่ครอบด้วย Kong เอง และ credential ผสมต่อคน/ทีม)

## การตัดสินใจที่ล็อกแล้ว

| หัวข้อ | ตัดสินใจ |
|---|---|
| Backend | Ruby on Rails 8 |
| Kong integration | Proxy + local read-model cache |
| Agent surface | MCP → Rails API เท่านั้น |
| Login | แบบ Primate — connection = host + basic auth, มีได้หลาย Kong |
| **Proxy หน้า Admin API** | **Kong เอง (loopback service)** |
| **Credential** | **มีทั้งต่อคนและร่วมกันทั้งทีม** |
| อยู่ร่วมกับ decK | tool สร้าง PR ของ decK YAML |
| ขอบเขต entity | services, routes, consumers, plugins + upstreams, targets, certificates, SNIs |
| จำนวน node | multi-node ตั้งแต่วันแรก |
| Pagination | keyset ตั้งแต่ต้น |
| Deployment | ยังไม่ deploy — ใช้กันภายในทีมก่อน |

---

## 1. เรื่องใหญ่ที่สุดของ rev นี้: tool จัดการสิ่งที่กั้นตัวมันเอง

Admin API ถูกครอบด้วย **Kong เอง** (loopback pattern: service ชี้ไป `http://127.0.0.1:8001`
+ route + basic-auth plugin) แปลว่า **เส้นทางเข้า Admin API ทั้งเส้นเป็น Kong entity ที่ tool จะเห็น
และแก้ได้** — service, route, plugin, consumer, credential ทั้งหมดจะโผล่ในตารางของ tool เอง

ผลที่ตามมามีทั้งดีและอันตราย ต้องจัดการทุกข้อ

### 1.1 อันตรายข้อที่หนึ่ง — ลบตัวเองออกจากบ้าน

ถ้าใครลบ route `admin-api` หรือ consumer ที่ถือ credential อยู่ → **เข้า Admin API ไม่ได้อีกเลย
และแก้กลับผ่าน Admin API ก็ไม่ได้เพราะมันหายไปแล้ว** ต้องกู้ด้วย `kubectl exec` เข้าไปแก้ DB
หรือ restart ด้วย declarative config

**Admin path guard — ทำที่ M0**

ตอน sync ให้ tool หาเส้นทางนี้เองแล้วมาร์คไว้:

```
1. เอา connection.admin_url → host + path
2. หา route ที่ match host/path นั้น
3. ไล่ route → service → ถ้า service.url ชี้ไป 127.0.0.1 / localhost
   ที่ port ของ admin_listen → นี่คือ admin path
4. มาร์ค is_admin_path = true ให้: service ตัวนั้น, route ทุกตัวของมัน,
   plugin ที่แปะบน service/route นั้น (basic-auth, acl, ip-restriction,
   rate-limiting, log), และ consumer ที่อยู่ในกลุ่ม ACL ที่ route นั้นอนุญาต
```

กฎที่ตามมา:

- **ลบ = บล็อกทั้งหมด** ใน UI ต้องพิมพ์ชื่อ connection + ติ๊ก "ฉันรู้ว่านี่จะทำให้เข้าไม่ได้"
  ใน **MCP บล็อกสนิท ไม่มี override** — agent ไม่มีทางลบเส้นทางเข้าได้
- **แก้ = เตือน** พร้อมแสดงว่าเปลี่ยนอะไรและอาจกระทบการเข้าถึงยังไง
- entity เหล่านี้ติด tag สงวน `kong-admin-path` และ **tool ปฏิเสธที่จะใส่ entity ที่ติด tag นี้
  ลงใน decK YAML ที่มัน render** ไม่ว่ากรณีใด

### 1.2 อันตรายข้อที่สอง — `deck gateway sync` ลบเส้นทางเข้า

นี่คือความเสี่ยงที่รุนแรงที่สุดในโครงการนี้ `deck gateway sync` **ลบทุกอย่างใน Kong
ที่ไม่มีในไฟล์** ถ้า admin path ไม่ได้อยู่ในไฟล์และไม่ได้ถูกกันด้วย select_tags →
merge ครั้งแรก = ไม่มีใครเข้า Admin API ของ env นั้นได้อีก รวมทั้ง CI ที่จะ sync รอบต่อไปด้วย

**วิธีรับมือ (ทำครบทุกชั้น ไม่ใช่เลือกชั้นเดียว)**

1. **อย่าให้ decK จัดการ admin path เลย** — ให้มันเกิดจาก Helm/bootstrap แทน
   แล้วกันออกจาก select_tags ที่ tool ใช้
2. tool ปฏิเสธที่จะ render entity ที่ติด `kong-admin-path` ลงใน YAML (ข้อ 1.1)
3. **CI gate:** block PR ถ้า `deck gateway diff --json-output` แสดงการลบหรือแก้
   entity ที่ติด tag `kong-admin-path`
4. CI gate ทั่วไป: block PR ที่มีจำนวน delete เกิน threshold
5. ซ้อมกับ uat ก่อนเสมอ

### 1.3 read-only credential — ทำแบบ Kong-native

rev ก่อนเสนอ nginx `if` block ซึ่งใช้ไม่ได้แล้ว เพราะ proxy คือ Kong
ท่าที่ตรงกับ Kong คือ **สอง route + ACL plugin** — เป็น config ล้วน ไม่มี custom code
อ่านง่ายเวลา CAB รีวิว

```yaml
# admin access path — จัดการด้วย Helm/bootstrap ไม่ใช่ decK
services:
  - name: admin-api
    url: http://127.0.0.1:8001
    tags: [kong-admin-path]
    routes:
      - name: admin-api-rw
        hosts: [kong-admin.internal]
        tags: [kong-admin-path]
        plugins:
          - name: basic-auth
            config: { hide_credentials: true }
          - name: acl
            config: { allow: [kong-admin-rw] }

      - name: admin-api-ro
        hosts: [kong-admin-ro.internal]     # คนละ host — สำคัญ
        methods: [GET, HEAD]                # ← กุญแจของ read-only
        tags: [kong-admin-path]
        plugins:
          - name: basic-auth
            config: { hide_credentials: true }
          - name: acl
            config: { allow: [kong-admin-ro] }

consumers:
  - username: jakkapat
    acls: [{ group: kong-admin-rw }]
  - username: ro-kongctl
    acls: [{ group: kong-admin-ro }]
```

**ทำไมต้องคนละ host:** router ของ Kong เลือก route จาก host/path/method **ก่อน**จะรู้ว่าใครเป็นคนยิง
ถ้าสอง route ใช้ host เดียวกัน `DELETE` จะไปเข้า route rw แทน — การจำกัด method
จึงไม่แยกตามผู้ใช้ ต้องแยก host (หรือแยก path prefix + `strip_path`) แล้วให้ ACL กันไม่ให้
consumer ข้ามฝั่ง

**พฤติกรรมที่ได้:** `DELETE https://kong-admin-ro.internal/services/x`
→ ไม่มี route ไหน match → Kong ตอบ `404 {"message":"no Route matched with those values"}`
tool ต้องรู้จัก signature นี้แล้วรายงานว่า *"credential นี้เขียนไม่ได้"* ไม่ใช่ *"ไม่พบ entity"*

**ทางเลือกที่เบากว่า** ถ้าไม่อยากมีสอง route — `pre-function` plugin บน admin route
(ทีมเขียน pre-function อยู่แล้ว):

```lua
local m = kong.request.get_method()
if m ~= "GET" and m ~= "HEAD" then
  local c = kong.client.get_consumer()
  if c and c.username:sub(1, 3) == "ro-" then
    return kong.response.exit(405, { message = "read-only credential" })
  end
end
```

เหลือ route เดียว กันออกจาก deck ง่ายกว่า แต่เป็น custom logic ที่ต้องอธิบายตอน CAB

> **แนะนำ:** ใช้สอง route + ACL เป็นหลัก (config ล้วน ตรวจสอบง่าย) —
> pre-function ไว้เป็นทางเลือกถ้าโครงสร้าง host ทำไม่ได้

### 1.4 error mapping — ต้องแยก "proxy ปฏิเสธ" ออกจาก "Admin API ตอบ"

พอมี Kong คั่นกลาง response ที่ได้อาจมาจากสองชั้นที่ต่างกันโดยสิ้นเชิง
ถ้าไม่แยก จะ debug กันตาย

| สถานะ | body | มาจาก | หมายถึง |
|---|---|---|---|
| 401 + `WWW-Authenticate` | `{"message":"Unauthorized"}` | basic-auth plugin | credential ผิดหรือไม่ได้ส่ง |
| 403 | `{"message":"You cannot consume this service"}` | ACL plugin | consumer ไม่อยู่ในกลุ่มที่อนุญาต |
| 404 | `{"message":"no Route matched with those values"}` | Kong router | **method ไม่ผ่าน (read-only ปฏิเสธ)** หรือ host/path ผิด |
| 404 | `{"message":"Not found"}` | Admin API | entity ไม่มีจริง |
| 429 | `{"message":"API rate limit exceeded"}` | rate-limiting plugin | ยิงถี่เกิน |
| 502 / 503 | Kong error | loopback service | Admin API listen ไม่ขึ้น |

`Kong::Client` ต้อง map ทั้งหกกรณีเป็น exception คนละตัว และ UI ต้องแสดงข้อความคนละแบบ

### 1.5 ข้อดีที่ได้ฟรี — Kong log กลายเป็น audit ชั้นที่สอง

พอ Admin API วิ่งผ่าน Kong ทุก request จะถูกบันทึกใน access log ของ Kong **พร้อมชื่อ consumer**
แปะ `file-log` หรือ `http-log` plugin บน admin route แล้วต่อเข้า log pipeline ที่ทีมมีอยู่ →
ได้ audit trail ที่ **อยู่นอกตัว tool** และจับได้แม้แต่คนที่ `curl` ตรงเข้า admin host
โดยไม่ผ่าน tool เลย

นี่ทำให้คำถาม *"ใครแก้ prod นอก PR"* เปลี่ยนจากการอนุมาน เป็นข้อเท็จจริงที่มีบันทึก —
และเป็น drift source ที่สี่ที่ tool เอามาแสดงคู่กับอีกสามอันได้

ของฟรีอื่นบน admin route: `ip-restriction` (จำกัดให้เฉพาะ subnet ของทีม),
`rate-limiting` (กัน agent ยิงถี่ตั้งแต่ชั้น gateway)

### 1.6 Bootstrap chicken-and-egg

Kong เครื่องใหม่ยังไม่มี admin path → tool เชื่อมไม่ได้ ต้อง bootstrap ก่อนด้วย
`kong config db_import` / Helm / declarative file **งานนี้อยู่นอก tool**
tool มีหน้าที่แค่ตรวจว่ามีแล้วหรือยัง และบอกให้ชัดถ้ายังไม่มี

### 1.7 กับดักของ decK กับ credential

**basic-auth ของ Kong เก็บ password แบบ hash** `deck dump` จึงได้ค่า hash ไม่ใช่ password จริง
ถ้าเอา YAML นั้นไป sync ที่อื่น password จะกลายเป็นสตริง hash นั้นแทน — พังเงียบ

→ **อย่าให้ decK จัดการ credential ของ consumer** ใช้ `--skip-consumers` หรือกันด้วย select_tags
tool ต้องปฏิเสธที่จะ render `basicauth_credentials` / `keyauth_credentials` ลง YAML เหมือนกัน

---

## 2. Identity — credential มีทั้งต่อคนและร่วมกันทั้งทีม

สภาพจริงคือมีทั้งสองแบบ ดังนั้นแทนที่จะบังคับให้เลือกอย่างใดอย่างหนึ่ง
ให้ tool **รู้ว่ากำลังใช้แบบไหนอยู่ แล้วปรับพฤติกรรมตาม**

### จำแนกตอน login

เนื่องจาก Admin API คือ Kong เอง tool จึงอ่านข้อมูล consumer ของตัวเองได้:

```
GET /consumers/<auth_username>  →  อ่าน tags
   tag "shared-credential"  → credential ร่วม
   ไม่มี tag                 → credential ต่อคน
```

ให้ทีมติด tag `shared-credential` บน consumer ที่ใช้ร่วมกัน (เช่น `kong-admin`, `deploy`)
เป็นงานครั้งเดียว ถ้าอ่านไม่ได้ ให้ fallback ไปที่ `shared_usernames` ใน `connections.yml`

### พฤติกรรมตามประเภท

| | credential ต่อคน | credential ร่วม |
|---|---|---|
| `actor_username` | username นั้น | username นั้น |
| `actor_operator` | = username | **ต้องระบุ ถามตอน login** (prefill จาก `git config user.email`) |
| เขียนได้เลยไหม | ได้ | **ไม่ได้จนกว่าจะมี operator** |
| แถบใน UI | ปกติ | *"ใช้ credential ร่วม — บันทึกในนาม \<operator\>"* |
| `rank >= 2` + write | re-auth ตามปกติ | re-auth **และ**ยืนยัน operator ใหม่ ไม่ใช้ค่าใน session เงียบ ๆ |
| PAT สำหรับ MCP | ผูก operator = เจ้าของ | ผูก operator ของคนที่ออก token · แสดงชัดในหน้า token |
| PR body / commit | ปกติ | เพิ่ม trailer `Changed-by: <operator>` |

**ถ้ามีทั้งสองแบบสำหรับ connection เดียวกัน tool ต้อง default ไปที่ credential ต่อคน**
และขึ้นเตือนเมื่อมีคนเลือกใช้ credential ร่วมเพื่อเขียนบน `rank >= 2`

**แนะนำเพิ่ม:** ให้ connection ของ uat/prod ผูกกับ credential read-only ที่เป็นของ *tool*
(`ro-kongctl`) แล้วให้ operator เป็นตัวระบุคนแทน — เพราะบน PR mode ตัว tool ไม่เขียนอยู่แล้ว
ตัวตนที่เป็นทางการคือ commit author ใน git

---

## 3. Login และ connection

**ไม่มี user database ของ tool เอง — credential ของ Kong Admin API *คือ* การ login**

```ruby
kong_connections
  id, name, env, rank,         # dev=0 sit=1 uat=2 prod=3
  color_tag,                   # ป้ายสีใน UI — prod = แดง
  admin_url,                   # บังคับ https:// ยกเว้น localhost
  auth_type,                   # basic | none | header
  auth_username,
  auth_secret_encrypted,       # ActiveRecord::Encryption — ไม่เคยคืนออก API
  credential_kind,             # personal | shared  (ตรวจจาก tag ของ consumer)
  credential_mode,             # session | stored
  access_level,                # rw | ro  (ตรวจจากผลของ probe ตอน connect)
  verify_ssl, ca_bundle_path,
  apply_mode, writable,        # direct | pr
  git_repo, git_branch, git_path, select_tags text[],
  kong_version, mode, plugins_available jsonb,
  admin_path_fingerprint,      # id ของ service/route/consumer ที่เป็นเส้นทางเข้า
  last_connected_at, last_status,
  sync_interval_seconds, last_synced_at, last_sync_status
```

### Flow ตอน login

1. หน้า **Connections** แสดง connection ทั้งหมด พร้อมสถานะและป้ายสี env
2. เลือก connection → ฟอร์ม username / password
3. `GET /` ด้วย Basic auth → 200 = ผ่าน เก็บ `kong_version` + plugin ที่เครื่องนั้นมี
4. **Probe สิทธิ์**: ยิง request ที่ไม่มีผลข้างเคียงแต่เป็น write method
   (เช่น `PATCH` ไปที่ id ที่ไม่มีจริง) → ถ้าได้ `no Route matched` → `access_level = ro`
   ถ้าได้ 404 ของ Admin API → `rw` · บันทึกไว้ UI จะได้ไม่ต้องให้ปุ่มที่กดไม่ได้
5. **จำแนก credential**: `GET /consumers/<username>` → อ่าน tag → `personal` หรือ `shared`
   ถ้า shared → ถาม operator ต่อ
6. **ตรวจ admin path**: หาเส้นทางเข้าแล้วเก็บ `admin_path_fingerprint`
7. แยก error ตามตารางข้อ 1.4 ไม่รวมเป็น "เชื่อมต่อไม่ได้" ก้อนเดียว
8. สร้าง session ผูกกับ connection + สลับ connection ได้จาก header

### สองโหมดของ credential

read-model ต้องใช้ credential ตอนที่ไม่มีใครเปิดเบราว์เซอร์ และ MCP ก็ต้องใช้

| | `session` | `stored` |
|---|---|---|
| เก็บที่ไหน | encrypted session cookie เท่านั้น **ไม่แตะ DB** | DB เข้ารหัสด้วย ActiveRecord::Encryption |
| Background sync | **ทำไม่ได้** — อ่านสดจาก Kong + cache ในหน่วยความจำอายุสั้น | ทำได้ |
| MCP ใช้ได้ไหม | **ไม่ได้** — ไม่ปรากฏใน MCP เลย | ได้ |
| filter/sort เต็มรูปแบบ | ได้เฉพาะชุดที่ดึงมา (`meta.partial: true`) | ได้เต็ม |
| เหมาะกับ | เครื่องที่ไม่ไว้ใจ, connection ที่ใช้นาน ๆ ครั้ง | ทุก connection ที่อยากให้ agent ทำงาน |

**ที่แนะนำ:** uat/prod ใช้ `stored` + credential `ro-kongctl` ที่เขียนไม่ได้ที่ชั้น Kong
→ ได้ sync, drift, MCP ครบ โดยไม่มีความเสี่ยงเรื่องเขียน

### แยก registry ออกจาก credential

```yaml
# config/connections.yml — อยู่ใน git ของทีม ไม่มี secret
- name: dev
  env: dev
  rank: 0
  admin_url: https://kong-dev-admin.internal
  apply_mode: direct
  color_tag: green
- name: prod
  env: prod
  rank: 3
  admin_url: https://kong-prod-admin-ro.internal   # host ของ route read-only
  apply_mode: pr
  color_tag: red
  select_tags: [managed-by-kongctl]
  shared_usernames: [kong-admin]                   # fallback ถ้าอ่าน tag ไม่ได้
```

credential แต่ละคนอยู่ใน DB ในเครื่องตัวเอง ไม่เคยเข้า git
**คนใหม่เข้าทีม:** pull repo → เห็น connection ครบ → ใส่ credential ของตัวเอง → พร้อมใช้

### กฎความปลอดภัยของ connection

- ปฏิเสธ `http://` ยกเว้น localhost — ข้ามได้ด้วย flag ในไฟล์ config เท่านั้น **ไม่ใช่ checkbox ใน UI**
- `verify_ssl` default true · internal CA ให้ใส่ `ca_bundle_path` **ไม่ใช่ปิด verify**
- ห้าม log header `Authorization` เด็ดขาด — มี spec ที่ assert ว่า log ไม่มีสตริง `Basic `
- credential ไม่เคยถูกคืนจาก API ใด ๆ — คืนแค่ `auth_username`, `has_credential`,
  `credential_kind`, `access_level`
- rate limit หน้า login ต่อ connection (และแปะ `rate-limiting` บน admin route ด้วยยิ่งดี)
- session timeout + re-auth ก่อน apply บน `rank >= 2`
- ปุ่ม "ลืมทุก credential" ล้าง stored credential ทั้งหมดทันที

---

## 4. ข้อจำกัดของ Kong Admin API

| ความสามารถ | Kong Admin API ให้อะไร | ต้องทำเองที่ไหน |
|---|---|---|
| Filter by tag | `?tags=a,b` (AND) / `?tags=a/b` (OR) · สูงสุด 5 tag | ขยายใน read-model |
| Search by name | เฉพาะ exact lookup | trigram บน read-model |
| Sort | **ไม่มีเลย** | ORDER BY บน read-model |
| Filter by date | **ไม่มี** ทั้งที่มี created_at/updated_at | range query บน read-model |
| Pagination | `?size=N` (max 1000) + opaque offset | keyset cursor ของเราเอง |
| Entity schema | `GET /schemas/:entity`, `/schemas/plugins/:name` | ใช้ตรง — สร้างฟอร์ม plugin อัตโนมัติ |
| Authentication | **ไม่มีเลยใน CE** | Kong loopback + basic-auth + ACL (ข้อ 1) |
| Vault backend | **CE มีแค่ `env`** — AKV เป็น Enterprise | ดูข้อ 8 |

> **หลักการ:** git = สิ่งที่ *ควรเป็น* (env ที่เป็น PR mode) · Kong = สิ่งที่ *เป็นอยู่* ·
> read-model = index ที่ทิ้งแล้วสร้างใหม่ได้

---

## 5. สถาปัตยกรรม

```
Claude Code ──▶ MCP server ──REST + PAT──┐
                                          ▼
Browser ──login: connection + basic auth──▶  Rails 8 "kongctl"
                                          │   └─ ถือ credential ไว้เอง
                    ┌─────────────────────┼─────────────────────┐
                    │                     │                     │
              apply_mode=direct     read ทุก connection    apply_mode=pr
                    │                     │                     │
                    ▼                     ▼                     ▼
        Kong loopback route rw      Postgres read-model    Git config repo
        (basic-auth + ACL rw)       (keyset, audit, plans) (decK YAML)
                    │                     ▲                     │
                    ▼                     │                     ▼
            Admin API :8001 ──────────────┘         PR → CAB → merge
            (dev / sit)          reconcile                  │
                                        ▲            CI: deck gateway sync
        Kong loopback route ro          │                   ▼
        (GET/HEAD + ACL ro) ────────────┘           Kong CE uat / prod
```

Rails: ConnectionAuth · AdminPathGuard · EntityQuery (keyset) · Redactor ·
ChangePlan (direct | pr) · DeckRenderer + GitClient · AuditLog · Kong::Client · SyncJob

**PAT ไม่เคยเห็น basic auth credential** — MCP เรียก Rails, Rails เป็นคนถือ credential

---

## 6. Apply mode

| | `direct` | `pr` |
|---|---|---|
| ใช้กับ | dev, sit | uat, prod |
| ปลายทาง | Admin API ผ่าน route rw | branch + PR ใน config repo |
| Credential ที่ใช้ | rw | **ro — เขียนไม่ได้ที่ชั้น Kong** |
| ใครอนุมัติ | คนกดใน tool (rank≥2 ต้อง re-auth) | reviewer + CAB บน PR |
| เห็นผลเมื่อ | ทันที (write-through) | หลัง merge + CI sync + reconcile |
| Audit trail | `audit_events` + Kong access log | ประวัติ PR + commit + Kong access log |

### เส้นทางของ PR mode

```
1. เสนอการเปลี่ยนแปลง                     → สร้าง change_plan
2. git pull config repo (shallow, cached) → parse YAML ของ env นั้น
3. แก้บนโครงสร้างที่ parse มา              → serialize กลับด้วย canonical serializer
4. deck gateway diff กับ Kong ของ env นั้น  // ใช้ credential ro — ปลอดภัย
5. เปิด branch + PR                       → body = YAML diff + ผล deck diff + ลิงก์ plan
                                             + trailer Changed-by ถ้าใช้ credential ร่วม
6. CI: deck gateway validate + diff --json-output → โพสต์เป็น check
   + gate: block ถ้าแตะ entity ที่ติด kong-admin-path
7. merge                                  → CI รัน deck gateway sync
8. ติดตาม pr_state                        → reconcile รอบถัดไปยืนยันของจริง drift หาย
```

### กฎเหล็กสี่ข้อ

**ก. สร้าง YAML จาก git เสมอ ห้ามจาก `deck dump`** — ไม่งั้นได้ diff ปลอมจากการเรียงลำดับ
**ข. `_info.select_tags` เป็นข้อบังคับ** — `deck gateway sync` ลบทุกอย่างที่ไม่มีในไฟล์
**ค. round-trip test byte-for-byte ตั้งแต่ M2**
**ง. ห้าม render entity ที่ติด `kong-admin-path` และ credential ของ consumer ลง YAML** (ข้อ 1.2, 1.7)

---

## 7. Data model

```ruby
kong_entities
  id, connection_id, entity_type, kong_id uuid,
  name         citext,          # display name
  logical_key  citext,          # ใช้เทียบข้าม connection
  tags text[], kong_created_at, kong_updated_at,
  parent_type, parent_kong_id, enabled,
  is_admin_path boolean,        # ← เส้นทางเข้า Admin API — ห้ามลบ ห้าม render ลง YAML
  data         jsonb,           # **ผ่าน redactor ก่อนเสมอ**
  digest       text,            # sha256 ของ data ที่ redact แล้ว
  not_after    timestamptz,     # certificate เท่านั้น
  first_seen_at, synced_at, deleted_at

  (connection_id, entity_type, name, id)
  (connection_id, entity_type, kong_created_at desc, id desc)
  (connection_id, entity_type, kong_updated_at desc, id desc)
  (connection_id, entity_type, not_after) where not_after is not null
  gin(tags) · gin(data jsonb_path_ops) · gin(name gin_trgm_ops)

change_plans
  id, connection_id, actor_username, actor_operator, actor_kind,
  operation, entity_type, target_kong_id,
  before/after/diff jsonb, apply_mode, base_updated_at,
  status, pr_url, pr_number, pr_state, commit_sha, deck_diff

audit_events   # append-only — actor = username + operator
```

### กฎ identity ของ entity

| entity_type | display name | logical_key | parent |
|---|---|---|---|
| service | `name` | `name` | — |
| route | `name` หรือ `id[0..7]` | `service.name` + `/` + `name` | service |
| consumer | `username` หรือ `custom_id` | `username` | — |
| plugin | `name` | `name` + `@` + scope | หลายแบบ |
| upstream | `name` | `name` | — |
| target | `target` (host:port) | `upstream.name` + `/` + `target` | upstream |
| certificate | SNI ตัวแรก / fingerprint[0..11] | เซ็ตของ SNI ที่เรียงแล้ว | — |
| sni | `name` | `name` | certificate |
| ca_certificate | `cert_digest[0..11]` | `cert_digest` | — |

**Spike เสร็จแล้ว (M5a, Kong 3.7.1 ทดสอบกับ stack ในเครื่อง):** `target` เป็น entity ธรรมดาที่แก้ไขได้ ไม่ใช่ append-only แล้ว
- `GET`/`PATCH`/`DELETE` ที่ `/upstreams/:upstream/targets/:id` ใช้ได้ (ใช้ `host:port` แทน id ก็ได้)
- **ไม่มี** `GET /targets` แบบ global (404) — ทุก path ต้องผ่าน upstream จึงต้องดึง target ทีละ upstream
- `(upstream, target)` ซ้ำ → 409 · `/targets/all` ยังตอบ 200 แต่เป็นของเก่า ไม่ใช้
- `updated_at` ของ target มีทศนิยมระดับ ms (entity อื่นเป็นวินาทีเต็ม) → optimistic lock เทียบที่ระดับ ms
- `healthchecks` ของ upstream ซ้อนลึก → ไม่ทำฟอร์มเอง แต่ให้ Kong ตรวจด้วย `POST /schemas/upstreams/validate` ตอนวางแผน

---

## 8. Certificate และความลับ

**Kong CE รองรับ vault backend แค่ `env`** — AKV backend เป็น Enterprise

**ทาง ก (แนะนำ):** `key: "{vault://env/cert-payments-key}"` โดย CSI Secret Store Driver
ป้อน env var เข้า pod ของ Kong จาก AKV → private key ไม่อยู่ทั้งใน git และ Kong DB
**ทาง ข (fallback):** `key: ${{ env "DECK_CERT_PAYMENTS_KEY" }}` · CI inject ตอน sync
→ git สะอาด แต่ plaintext ไปอยู่ใน Kong DB

**กฎของ tool เหมือนกันทั้งสองทาง:**
- redactor ทำงาน**ก่อน** `data` เขียนลง read-model — `certificates.key`,
  `basicauth_credentials.password` (แม้เป็น hash), `keyauth_credentials.key`,
  field ที่ schema ทำเครื่องหมาย `encrypted`/`referenceable` → `"[REDACTED]"`
- MCP ไม่คืนค่าเหล่านี้ทุกกรณี **ไม่มี flag ให้ปลด**
- แคชเฉพาะ metadata ของ cert: id, tags, SNIs, subject, issuer, `not_before`/`not_after`, fingerprint
- `digest` คำนวณจาก data ที่ redact แล้ว

**ผลพลอยได้:** dashboard cert หมดอายุข้ามทุก connection + MCP tool `kong_certs_expiring`

**ผลการ spike (M5b, Kong 3.7.1):** `{vault://env/cert-x-key}` อ่านตัวแปร `CERT_X_KEY` (ตัวพิมพ์ใหญ่, `-` → `_`) และ Kong เก็บ/คืนค่า reference ตามที่ส่งมา ไม่เคยคืน PEM · **Kong ไม่ตรวจ reference ตอนเขียน** — ตัวแปรที่ไม่มีอยู่หรือ key ที่ไม่ตรงกับ cert ก็ได้ 201 และ TLS ของ hostname นั้นจะล้ม (`tlsv1 alert internal error`) ตอนใช้งานจริง → tool จึงบังคับให้ยืนยันว่าตัวแปรมีอยู่ก่อน apply และบันทึกลง audit · tool ไม่รับ private key ในรูป PEM ทุกช่องทาง

---

## 9. API contract — filter, ordering, keyset

```
GET /api/v1/entities

  connection=prod  type=service   # บังคับทั้งคู่
  q=payment                       # trigram บน name + host + path
  tags=core,payment               # AND (ไม่จำกัด 5 tag)
  tags_any=beta,canary            # OR
  tags_none=deprecated            # NOT — Kong ทำไม่ได้
  created_after=  created_before=  updated_after=
  sort=-updated_at                # allowlist: name|created_at|updated_at
  limit=50   cursor=<opaque>
  fields=id,name,tags,updated_at  # สำคัญมากสำหรับ MCP — ลด token
  include_total=false

{ "data": [ … ],
  "meta": { "has_more": true, "next_cursor": "eyJrIjpb…",
            "connection": "prod", "credential_mode": "stored",
            "access_level": "ro", "credential_kind": "shared",
            "synced_at": "…", "stale_seconds": 47,
            "desired_state": "git@…#a3f19c2" } }
```

- ทุก sort ต้องมี tiebreaker: `ORDER BY kong_updated_at DESC, id DESC`
- index ต้องตรงกับ sort key เป๊ะ → **จำกัด sort เป็น allowlist** ห้ามต่อ input เข้า ORDER BY
- cursor = base64url `{"k":[…,<id>],"s":"-updated_at","f":"<hash ของ filter>"}` + HMAC
- ไม่มี `total` ฟรี — UI ใช้ปุ่ม "โหลดเพิ่ม"
- `session` mode → `meta.partial: true` + แบนเนอร์ใน UI
- `access_level: ro` → UI ซ่อนปุ่มเขียนตั้งแต่แรก ไม่ใช่ให้กดแล้วค่อย error

---

## 10. Write path

| # | ขั้นตอน | direct | pr |
|---|---|---|---|
| 1 | Validate | schema จริงของ Kong (แคชต่อ connection+version) | + `deck gateway validate` |
| 2 | Guardrails | `access_level=rw`? · `is_admin_path`? · tag `protected`? · dependency? | + tag ต้องอยู่ใน `select_tags` และห้ามเป็น `kong-admin-path` |
| 3 | Identity | credential ร่วม → ต้องมี operator | เหมือนกัน + ใส่ trailer ใน commit |
| 4 | Plan | `change_plan` + before/after/diff · หมดอายุ 15 นาที | + render YAML จาก git + `deck gateway diff` |
| 5 | Review | คนกดยืนยัน · rank≥2 ต้อง re-auth | reviewer + CAB บน PR |
| 6 | Execute | ยิง Admin API · optimistic lock บน `updated_at` | เปิด PR · CI sync ตอน merge |
| 7 | Record | write-through + `audit_event` | `audit_event` + ติดตาม pr_state |

---

## 11. Drift สี่ทาง

| เทียบอะไร | แปลว่า | ทำยังไง |
|---|---|---|
| cache ≠ Kong | cache เก่า | reconcile รอบถัดไปแก้เอง |
| Kong ≠ git (pr mode) | **มีคนแก้ Kong ตรง ข้าม PR** | แจ้งเตือน |
| git ≠ Kong หลัง merge | CI sync พังหรือยังไม่รัน | เช็ค pipeline |
| **Kong access log มี write ที่ไม่มี change_plan** | **มีคนยิง Admin API ตรงโดยไม่ผ่าน tool** | ระบุตัวได้จาก consumer ใน log |

คู่ที่สี่มาจากข้อ 1.5 — เป็นชั้นเดียวที่จับคนที่ไม่ใช้ tool เลยได้

**Sync สามชั้น:** write-through หลัง mutate (direct) · full reconcile ต่อ connection ทุก 2–5 นาที
แบบ jitter และ **fail closed** · digest diff → drift event

---

## 12. MCP server

| Tool | | ทำอะไร |
|---|---|---|
| `kong_connections` | read | list connection ที่ PAT เข้าถึงได้ + version, apply_mode, access_level, drift |
| `kong_search` | read | ตัวหลัก — connection + type + filter/sort/keyset คืนตารางย่อ |
| `kong_get` | read | entity เต็มพร้อม relation |
| `kong_schema` | read | schema ของ entity/plugin |
| `kong_diff` | read | เทียบสอง connection ด้วย `logical_key` หรือเทียบ Kong กับ git |
| `kong_drift` | read | รายการที่ Kong ต่างจาก git (รวมคู่ที่สี่จาก access log) |
| `kong_certs_expiring` | read | cert ใกล้หมดอายุข้ามทุก connection |
| `kong_audit` | read | ประวัติการเปลี่ยนแปลง |
| `kong_plan` | **write** | เสนอ create/update/delete → diff + plan_id · ไม่มี side effect |
| `kong_apply` | **write** | direct → ยิง Admin API · pr → เปิด PR แล้วคืน URL |
| `kong_export` | read | ส่งออก decK YAML ตาม filter (ตัด admin path + credential ออกเสมอ) |

**กฎกันพัง — สี่ชั้นซ้อนกัน**
1. `connection` เป็นพารามิเตอร์บังคับทุก tool ไม่มี default
2. `kong_apply` บน `rank >= 2` ทำได้เฉพาะ PR mode
3. entity ที่ `is_admin_path` — **MCP ลบไม่ได้เลย ไม่มี override**
4. credential ของ prod เขียนไม่ได้อยู่แล้วที่ชั้น Kong (route ro)

**PAT** ผูกกับ operator + เซ็ตของ connection ที่เป็น `stored` ·
connection ที่เป็น `session` ไม่ปรากฏใน MCP เลย ·
ถ้า PAT ออกภายใต้ credential ร่วม ต้องบันทึก operator ของคนที่ออก ·
PAT ไม่เคยเห็น basic auth credential

**ประหยัด token:** default ของ `kong_search` คืนแค่ 4 field —
service 400 ตัวกิน ~2k token แทน 80k

TypeScript SDK ใน `mcp/` (~350 บรรทัด) stdio transport

---

## 13. ความปลอดภัยรวม

| ชั้น | ตอนนี้ — local team tool | ตอน deploy |
|---|---|---|
| ตัวตนผู้ใช้ | basic auth ของ Kong เอง + `operator` เมื่อใช้ credential ร่วม | เพิ่ม OIDC ครอบ แล้ว map เป็น operator |
| กั้น Admin API | Kong loopback + basic-auth + ACL + ip-restriction | เหมือนเดิม + NetworkPolicy |
| สิทธิ์เขียน dev/sit | ACL กลุ่ม rw | + RBAC ในtool |
| **สิทธิ์เขียน prod** | **route ro (GET/HEAD) + ทางเข้าเดียวคือ PR** | เหมือนเดิม |
| ป้องกันลบเส้นทางเข้า | `is_admin_path` guard + tag สงวน + CI gate | เหมือนเดิม |
| เก็บ credential | `stored` = ActiveRecord::Encryption ในเครื่อง · `session` = cookie | AKV ผ่าน CSI driver |
| Audit ของ dev/sit | `audit_events` ในเครื่อง + **Kong access log (ส่วนกลาง)** | shared Postgres |
| Audit ของ prod | ประวัติ PR ใน git + **Kong access log** | เหมือนเดิม |
| Private key ของ cert | redactor (ข้อ 8) | เหมือนเดิม |

**Kong access log ทำให้โหมด local ปลอดภัยขึ้นมาก** — ถึง DB ของ tool จะกระจายตามเครื่องแต่ละคน
แต่ access log ของ Kong เป็นส่วนกลางและบันทึกทุก request พร้อมชื่อ consumer

---

## 14. หน้าบ้าน

**Rails 8 + Hotwire (Turbo Frames/Streams) + Stimulus + ViewComponent + Tailwind**

**หน้าจอ**
- **Connections** — list / add / edit / test / delete พร้อมสถานะ, ป้ายสี, `access_level`, `credential_kind`
- **Login ของ connection** — ฟอร์ม basic auth + ช่อง operator (ถ้าเป็น credential ร่วม)
  + error ที่แยกตามตารางข้อ 1.4
- **Connection switcher ใน header** — prod = แถบแดงเต็ม + ป้าย "read-only" ถ้าเป็น ro
  + ป้าย "credential ร่วม — บันทึกในนาม X"
- ตาราง entity + ฟิลเตอร์ติดบน + saved view + "โหลดเพิ่ม"
  · แถวที่ `is_admin_path` มีไอคอนกุญแจและปุ่มลบถูกปิด
- รายละเอียด: Overview / ลูก ๆ / Plugins / Raw JSON / History
- Review diff ก่อน apply · Audit log · drift (สี่ทาง) · cert หมดอายุ · PR ค้าง
- หน้า PAT: ออก / ดู / เพิกถอน พร้อมบอกว่าแตะ connection ไหนได้

**ฟอร์ม plugin สร้างจาก schema:** ดึง `GET /schemas/plugins/:name` มา render อัตโนมัติ
แล้วเขียน custom UI ทับเฉพาะที่ใช้บ่อย รองรับ custom plugin ได้ฟรี

**ป้ายสีคือ guardrail ที่ถูกที่สุดและได้ผลที่สุด** ในการกัน "ทำผิดเครื่อง"

---

## 15. แผนการดำเนินงาน

### M0 — ตั้งฐาน + connection + admin path guard (4–5 วัน)
- Rails 8 + Postgres + Solid Queue, RSpec, CI
- **`compose.yaml`: Kong CE สอง node ที่ครอบ Admin API ด้วยตัวเอง (loopback + basic-auth + ACL)
  พร้อม route rw และ ro** → ทดสอบ login, สิทธิ์, และ error ทุกแบบจริงตั้งแต่วันแรก
- `kong_connections` + CRUD + ฟอร์ม login + test connection + **probe `access_level`**
- **จำแนก `credential_kind` จาก tag ของ consumer** + ช่อง operator
- **AdminPathGuard**: หา admin path, มาร์ค `is_admin_path`, บล็อกการลบ
- ActiveRecord::Encryption + `credential_mode` สองแบบ
- `Kong::Client` — basic auth, timeout, retry backoff, **error mapping ครบหกกรณีของข้อ 1.4**
- **Redactor + spec** และ spec ที่ assert ว่า log ไม่มีสตริง `Basic `
- โหลด `config/connections.yml` · หน้า health

### M1 — Thin vertical slice: Services, direct mode (~1.5 สัปดาห์)
- `kong_entities` + sync services + digest
- `EntityQuery` ครบ filter/sort/**keyset** + cursor ที่เซ็นแล้ว + spec เคสขอบ
- REST `/api/v1` + หน้าเว็บ list & detail + connection switcher พร้อมป้ายสีและป้าย ro/shared
- create/update/delete แบบ direct ผ่าน plan→apply + audit (username + operator) + optimistic lock
- PAT + MCP 4 tool: `kong_connections`, `kong_search`, `kong_plan`, `kong_apply`

**เกณฑ์ผ่าน:** สั่ง Claude Code ว่า *"หา service ใน connection dev ที่ติด tag payment
แก้ล่าสุดใน 7 วัน เรียงตาม updated_at แล้วเสนอเพิ่ม tag deprecated ให้ตัวที่ไม่มี route"*
→ ได้ diff ให้กดอนุมัติ · audit ระบุคนได้ · ลบ admin path ไม่ได้ · เห็นเฉพาะ connection ที่ผูกกับ token

### M2 — decK PR mode (~1.5–2 สัปดาห์)
- `GitClient` + clone/pull cache
- `DeckRenderer`: parse → mutate → serialize + **round-trip test byte-for-byte**
- บังคับ `select_tags` · **ตัด `kong-admin-path` และ credential ของ consumer ออกจาก YAML เสมอ**
- `deck gateway validate` / `diff` ใส่ PR body + trailer `Changed-by`
- **CI gate: block PR ที่แตะ entity ติด tag `kong-admin-path` หรือมี delete เกิน threshold**
- ติดตามสถานะ PR + หน้ารายการ PR ค้าง
- **ตั้ง connection ของ uat ให้ใช้ route ro แล้วพิสูจน์ว่าเขียนไม่ได้จริง**

**เกณฑ์ผ่าน:** เปลี่ยน service ใน uat แล้วได้ PR diff สะอาด ไม่มี noise ·
การพยายามเขียนตรงได้ `no Route matched` และ tool รายงานว่า "credential นี้เขียนไม่ได้" ·
PR ที่แตะ admin path ถูก CI block

### M3 — Routes + Consumers (~1 สัปดาห์)
- route↔service, แท็บลูก, cascade preview ก่อนลบ
- credential ของ consumer (key-auth, basic-auth) — sub-entity + redactor
- **ระวังเป็นพิเศษ: consumer ที่ถือ credential ของ admin path ห้ามลบ**

### M4 — Plugins (~1.5 สัปดาห์)
- catalog จาก `GET /` ของแต่ละ connection
- ฟอร์มจาก schema + override สำหรับ plugin ที่ใช้บ่อย
- ผูก plugin ระดับ global / service / route / consumer + toggle
- **plugin บน admin route (basic-auth, acl, ip-restriction) แสดงเป็น read-only**

### M5 — Upstreams, Targets, Certificates, SNIs (~1–1.5 สัปดาห์)
- upstream + target (spike semantic ก่อน)
- certificate + SNI + ca_certificate พร้อม parse `not_after`, subject, issuer, fingerprint
- dashboard cert หมดอายุ + `kong_certs_expiring`
- ตัดสินใจทาง ก หรือ ข ของข้อ 8

### M6 — Drift + hardening (~1 สัปดาห์)
- **drift สี่ทาง** รวมการดูด Kong access log มาเทียบกับ change_plan
- rate limit, circuit breaker, structured log, Prometheus metric
- seam ของ multi-operator
- `deck` import: ดูด YAML ที่มีอยู่เข้ามาเป็น baseline

รวมประมาณ **8–9 สัปดาห์** · ใช้งานจริงได้ตั้งแต่จบ M2

---

## 16. ความเสี่ยง

| ระดับ | ความเสี่ยง | วิธีรับมือ |
|---|---|---|
| **สูงสุด** | **`deck gateway sync` ลบ admin path → ไม่มีใครเข้า Admin API ได้อีก รวมทั้ง CI** | อย่าให้ deck จัดการ admin path · tag สงวน `kong-admin-path` · tool ไม่ render ลง YAML · CI gate · ซ้อมกับ uat |
| **สูงสุด** | **tool ลบ/แก้เส้นทางเข้าของตัวเอง** | `is_admin_path` guard · ลบต้องพิมพ์ชื่อ + ติ๊กยืนยัน · **MCP บล็อกสนิท** |
| **สูง** | YAML round-trip ไม่ nice → PR เต็ม noise จนไม่มีใครรีวิว | round-trip test เป็น gate ของ M2 · สร้างจาก git เสมอ |
| **สูง** | private key ของ cert / credential ของ consumer หลุดเข้า read-model, git, MCP | redactor ที่ **M0** · digest หลัง redact · ไม่มี flag ปลด · ไม่ render credential ลง YAML |
| **สูง** | credential ร่วมทำให้ audit ระบุคนไม่ได้ | บังคับ `operator` ก่อนเขียน · trailer ใน commit · default ไป credential ต่อคนถ้ามี · **Kong access log เป็นชั้นสำรอง** |
| **สูง** | credential ที่เก็บไว้หลุดจากเครื่องที่ถูกเจาะ | prod ใช้ route ro · ActiveRecord::Encryption · ปุ่มลืมทุก credential · ไม่มี API ที่คืน credential |
| กลาง | `deck dump` ได้ password แบบ hash แล้ว sync ต่อทำให้ password พัง | ไม่ให้ deck จัดการ credential (`--skip-consumers` / select_tags) |
| กลาง | สับสนระหว่าง "proxy ปฏิเสธ" กับ "Admin API ตอบ" | error mapping หกกรณี (ข้อ 1.4) · `access_level` ซ่อนปุ่มที่กดไม่ได้ |
| กลาง | basic auth บน HTTP = password plaintext | ปฏิเสธ `http://` ยกเว้น localhost · ข้ามได้ทาง config file เท่านั้น |
| กลาง | `credential_mode=session` ทำให้ filter/sort ไม่ครบแล้วผู้ใช้ไม่รู้ | `meta.partial: true` + แบนเนอร์ |
| กลาง | Kong CE ไม่มี AKV vault backend | ทาง ก หรือ ข ของข้อ 8 — ตัดสินใจก่อน M5 |
| กลาง | keyset ผิดแล้วแถวซ้ำ/หายแบบเงียบ | tiebreaker ทุก sort · index ตรง sort key · spec ที่ insert ระหว่างไล่ page |
| กลาง | ทำผิดเครื่อง | ป้ายสี · prod แถบแดง · re-auth บน rank≥2 · MCP บังคับระบุ connection |
| กลาง | Kong version ต่างกันข้าม connection → schema ต่าง | แคช schema ต่อ connection ต่อ version · แจ้งเตือนเมื่อไม่ตรง |
| ต่ำ | agent ยิงถี่จน Admin API รับไม่ไหว | อ่านจาก cache · rate limit ต่อ token · **`rate-limiting` plugin บน admin route** |

---

## 17. ที่ยังต้องรู้

**ก่อน M0**
1. **admin route ตอนนี้แยก rw/ro แล้วหรือยัง** ถ้ายัง — จะสร้างเพิ่มได้ไหม
   (สอง host หรือสอง path) หรือจะใช้ท่า pre-function แทน
2. **admin path ตอนนี้เกิดจากอะไร** — Helm values / declarative bootstrap / คนสร้างมือ
   → กำหนดว่าจะกันออกจาก deck ยังไง
3. **consumer ที่ใช้ร่วมกันมีตัวไหนบ้าง** → เอาไปติด tag `shared-credential` ครั้งเดียว

**ก่อน M2**
4. **Git host อะไร** — GitHub / GitLab / Azure DevOps / Bitbucket
5. **config repo มีอยู่แล้วหรือยัง** และ prod จัดการด้วย deck 100% หรือบางส่วน
6. **decK เวอร์ชันไหน** — `deck sync` vs `deck gateway sync`

**ก่อน M5**
7. **ตอนนี้ private key ของ cert อยู่ที่ไหน** — inline ใน Kong, env var, หรือ AKV แล้ว

---

*อ้างอิงพฤติกรรมของ Kong Gateway 3.x และ decK — ตรวจกับเวอร์ชันที่ใช้จริงก่อนล็อก contract*
