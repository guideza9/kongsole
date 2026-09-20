# Kong Admin Route — Prerequisite Checklist

เอกสารนี้เป็นเช็คลิสต์ actionable ที่สรุปมาจาก docs/DESIGN.md §1 (เรื่องใหญ่ที่สุดของ rev นี้:
tool จัดการสิ่งที่กั้นตัวมันเอง) อ่านที่นั่นถ้าต้องการเหตุผลเต็ม ที่นี่มีแต่ "ต้องมีอะไรบ้าง"

## สถานะปัจจุบัน — มีแล้ว (ตาม docker/kong/bootstrap.sh)

- [x] service `admin-api` → loopback `http://127.0.0.1:8001`, tag `kong-admin-path`
- [x] route `admin-api-rw` — host `kong-admin.internal`, ทุก method, tag `kong-admin-path`
- [x] route `admin-api-ro` — host `kong-admin-ro.internal` (**คนละ host** จาก rw โดยตั้งใจ —
      Kong router เลือก route จาก host/path/method ก่อนรู้ว่าใครยิง ถ้าใช้ host เดียวกัน
      DELETE จะหลุดไปเข้า route rw ได้), method จำกัดแค่ `GET`/`HEAD`, tag `kong-admin-path`
- [x] plugin **basic-auth** (`config.hide_credentials=true`) บนทั้งสอง route
- [x] plugin **acl** บนทั้งสอง route — allow `kong-admin-rw` / `kong-admin-ro` ตามลำดับ
- [x] consumer อย่างน้อยฝั่งละ 1 ตัว — rw: `jakkapat` (personal), ro: `ro-kongctl` (personal),
      ตัวอย่าง shared credential: `kong-admin` (tag `shared-credential`)
- [x] `AdminPathGuard` (app/services/kong/admin_path_guard.rb) ตรวจจับ admin path จาก
      `service.url` ที่ชี้ loopback (`127.0.0.1` / `localhost` / `::1`) — ไม่ได้พึ่ง tag อย่างเดียว
      จึงจับได้แม้ tag หลุดหรือไม่ได้ติด

**สรุป:** prerequisite ระดับ M0 ที่ถามมา (basic-auth + acl) มีครบแล้วสำหรับ dev/local —
และมีมากกว่านั้นคือ route แยก rw/ro + guard ฝั่ง tool ด้วย

## ที่ยังขาด — แนะนำเพิ่มก่อนขึ้น uat/prod

1. **Audit log ชั้นที่สอง** (§1.5): plugin `file-log` หรือ `http-log` บน admin-api-rw/ro
   ต่อเข้า log pipeline ของทีม — เป็น audit trail นอกตัว tool จับคนที่ `curl` ตรงเข้า
   admin host โดยไม่ผ่าน tool ได้ด้วย ยังไม่ได้เพิ่มใน bootstrap.sh
2. **ip-restriction** บน admin route — จำกัดเฉพาะ subnet ของทีม (ยังไม่มี)
3. **rate-limiting** บน admin route — กัน agent ยิงถี่ตั้งแต่ชั้น gateway
   (`Kong::Client` มี error mapping รองรับ 429 อยู่แล้ว แต่ยังไม่มี plugin จริงมา trigger case นี้)
4. **นอกตัว tool — ต้องทำก่อนใช้งานจริง:**
   - Bootstrap ของแต่ละ env จริง (dev/sit/uat/prod) ต้องรัน `kong config db_import` /
     Helm / declarative file ให้มี admin path นี้อยู่ก่อน tool ถึงจะเชื่อมได้ (chicken-and-egg, §1.6)
   - CI gate: block PR ถ้า `deck gateway diff --json-output` แตะ entity ที่ tag `kong-admin-path`
   - CI gate: block PR ที่มีจำนวน delete เกิน threshold
   - ซ้อม sync กับ uat ก่อนทุกครั้งที่จะทำกับ prod
   - decK ต้องตั้ง `--skip-consumers` หรือกันด้วย select_tags ไม่ให้จัดการ
     `basicauth_credentials`/`keyauth_credentials` ของ consumer (§1.7) — กัน password
     กลายเป็น hash string ตอน sync ข้าม env
5. **Host-based routing ของ env จริง** — ต้องมี DNS/host header `kong-admin.internal`
   และ `kong-admin-ro.internal` ใช้งานได้จริงหลัง proxy/ingress ของ env นั้น
   (docker-compose ตอนนี้ใช้ได้แค่ local)
6. **Identity สำหรับ shared credential** — ถ้า env ไหนใช้ credential ร่วมกันทั้งทีม
   consumer นั้นต้องติด tag `shared-credential` จริง (ให้ `Kong::CredentialClassifier`
   จับได้) และต้องบังคับกรอก `operator` (prefill จาก `git config user.email`) ก่อน write ได้

## Reference

- `docs/DESIGN.md` §1 ทั้งหมด, §1.3 ตัวอย่าง Kong declarative config ของ admin path
- `docker/kong/bootstrap.sh` — implementation จริงของ M0 (rw/ro route + basic-auth + acl + consumer)
- `app/services/kong/admin_path_guard.rb`, `credential_classifier.rb`, `client.rb`
  (six-way error mapping: 401 basic-auth / 403 acl / 404 no-route vs 404 not-found / 429 / 502-503)
