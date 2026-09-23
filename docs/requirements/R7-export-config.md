# R7 — Export config ทั้งหมด พร้อม custom template

## ปัญหา
ยัง export config ไม่ได้ และอยากปรับรูปแบบก่อน export

## ผู้ใช้และสถานการณ์
(ให้เจ้าของงานเติม: export ไปใช้ทำอะไร เช่น backup, ย้ายระหว่าง env, เอกสาร, ส่งทีมอื่น)

## สิ่งที่ต้องการ
Export config ทั้งหมดของ connection หรือ project และเลือก/แก้ template ก่อน export

## เกณฑ์ยอมรับ (ร่าง)
- [ ] เลือกขอบเขตได้: project, env, connection, ชนิด entity, tag
- [ ] preview ก่อนดาวน์โหลด
- [ ] ผลลัพธ์ไม่มี credential, private key ของ certificate หรือ entity ที่เป็น admin path
      (แทนด้วย vault reference หรือ placeholder) — มี test อัตโนมัติ
- [ ] export ซ้ำจากข้อมูลเดิมได้ไฟล์เหมือนเดิมทุก byte
- [ ] เลือกและแก้ template ได้ก่อน export
- [ ] ผ่านเกณฑ์ของ R3

## นอก scope
- import ไฟล์กลับเข้า Kong (ถ้าต้องการ ต้องเป็น requirement แยกเพราะกระทบกฎ apply_mode)

## ตัดสินแล้ว
- decK YAML สำหรับ PR mode render จาก git ไม่ใช่ `deck dump`
- ห้าม render `basicauth_credentials` / `keyauth_credentials`

## คำถามค้าง (ต้องคุยก่อนวางแผน)
1. "template" หมายถึงอะไร (ให้ AI เสนอทางเลือก):
   ตัวกรอง entity/field/tag / แทนค่าตาม env เช่น host, upstream / รูปแบบไฟล์อื่น เช่น JSON หรือเอกสาร
2. env ที่ `apply_mode = direct` ไม่มีข้อมูลใน git — export จากข้อมูลใน Kong ได้ไหม
   (ขัดกับกฎ render จาก git หรือไม่ ให้ AI วิเคราะห์)
3. template เก็บที่ไหน และแชร์ในทีมอย่างไร
