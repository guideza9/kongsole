# R7 — Export config ทั้งหมด พร้อม custom template

## ปัญหา
ยัง export config ไม่ได้ และอยากปรับรูปแบบก่อน export

## ผู้ใช้และสถานการณ์
export decK YAML ของ connection เพื่อนำไป promote ขึ้น env อื่นเอง

## สิ่งที่ต้องการ
Export ด้วย `deck gateway dump --select-tag <ค่าที่ผู้ใช้กรอก>` ของ connection เดียว

## เกณฑ์ยอมรับ (ร่าง)
- [ ] เลือก project/env (connection) และ select_tag อย่างน้อย 1 ค่า · ห้าม `kong-admin-path`
- [ ] preview ก่อนดาวน์โหลด
- [ ] ผลลัพธ์ไม่มี credential, private key ของ certificate หรือ entity ที่เป็น admin path
      (แทนด้วย vault reference หรือ placeholder) — มี test อัตโนมัติ
- [ ] export ซ้ำจาก Kong ที่สถานะเดิมได้ไฟล์เหมือนเดิมทุก byte (ไม่มีเวลาใน body)
- [ ] ไฟล์มี `_info.select_tags` และ header บอกว่าเป็น snapshot, ครอบทั้ง scope ของ tag,
      และ env PR mode ต้องนำเข้าผ่าน PR ของ repo project ไม่ใช่ `deck gateway sync` ด้วยมือ
- [ ] MCP `kong_export` ใช้ sanitizer เดียวกัน
- [ ] ผ่านเกณฑ์ของ R3

## นอก scope
- import ไฟล์กลับเข้า Kong (ถ้าต้องการ ต้องเป็น requirement แยกเพราะกระทบกฎ apply_mode)

## ตัดสินแล้ว
- decK YAML สำหรับ PR mode render จาก git ไม่ใช่ `deck dump`
- ห้าม render `basicauth_credentials` / `keyauth_credentials`
- ไม่มี template · export จาก direct env ได้ · ต้องแก้กฎข้อ 2 ของ CLAUDE.md ก่อน (`docs/plans/design-amendments.md` §B)

## คำถามค้าง (เดิม — ตอบแล้วตามส่วน "ตัดสินแล้ว")
1. "template" หมายถึงอะไร (ให้ AI เสนอทางเลือก):
   ตัวกรอง entity/field/tag / แทนค่าตาม env เช่น host, upstream / รูปแบบไฟล์อื่น เช่น JSON หรือเอกสาร
2. env ที่ `apply_mode = direct` ไม่มีข้อมูลใน git — export จากข้อมูลใน Kong ได้ไหม
   (ขัดกับกฎ render จาก git หรือไม่ ให้ AI วิเคราะห์)
3. template เก็บที่ไหน และแชร์ในทีมอย่างไร
