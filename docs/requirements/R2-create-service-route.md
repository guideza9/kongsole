# R2 — สร้าง service และ route

## ปัญหา
ยังสร้าง service และ route จาก Kongsole ไม่ได้

## ผู้ใช้และสถานการณ์
Engineer ที่ต้องเปิด API ใหม่บน dev/sit ก่อน แล้วค่อยส่งต่อไป env สูงกว่าผ่าน PR

## สิ่งที่ต้องการ
สร้าง service และ route จาก UI ได้อย่างปลอดภัย โดยพฤติกรรมเปลี่ยนตาม `apply_mode` ของ connection

## เกณฑ์ยอมรับ (ร่าง)
- [ ] ฟอร์มสร้าง service และ route (route สร้างภายใต้ service) ตรวจความถูกต้องก่อนส่ง
- [ ] ก่อนบันทึกมี preview:
  - `direct`: แสดงสิ่งที่จะถูกสร้างใน Kong
  - `pr`: แสดง diff ของ decK YAML ที่จะเข้า changeset
- [ ] `apply_mode = pr` เพิ่มเข้า changeset (R8) และไม่เรียก Admin API แบบเขียนเลย — มี test ยืนยัน
- [ ] credential ที่เป็น read-only ไม่เห็นปุ่มสร้าง (ใช้ผล probe `access_level` ตอน login)
- [ ] ใส่ tag ตาม `select_tags` ของ connection ให้อัตโนมัติ
- [ ] เตือนเมื่อ path/host ของ route ใหม่ซ้อนกับ route เดิมใน connection เดียวกัน
- [ ] error จาก Kong แสดงตาม error mapping 6 แบบของ `Kong::Client` ไม่รวมเป็น "เชื่อมต่อไม่ได้"
- [ ] ผ่านเกณฑ์ของ R3

## นอก scope
- สร้างหลายรายการพร้อมกันจากไฟล์ (bulk import)
- แก้ไขและลบ (ถ้ายังไม่มี ให้ AI แจ้งใน brainstorming ว่าควรรวมหรือไม่)

## ตัดสินแล้ว
- service อยู่ใน M1, route อยู่ใน M3

## คำถามค้าง
1. MCP สร้าง service/route ได้ด้วยไหม ถ้าได้ จำกัด rank หรือไม่
2. ต้องมีค่าตั้งต้นต่อ project ไหม (protocol, timeout, retries)
3. ต้องการ flow "สร้างบน dev แล้ว promote ไป env ถัดไป" ในรอบนี้ไหม
