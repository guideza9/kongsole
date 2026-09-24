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
- [ ] ไม่เห็นปุ่มสร้างเมื่อ apply_mode ยังไม่กำหนด หรือเป็น direct แต่ credential เป็น read-only
      (PR mode ใช้ credential read-only โดยตั้งใจ จึงยังเห็นปุ่ม — DESIGN.md §6)
- [ ] ใส่ tag ตาม `select_tags` ของ connection ให้อัตโนมัติ
- [ ] เตือนเมื่อ path/host ของ route ใหม่ซ้อนกับ route เดิมใน connection เดียวกัน
- [ ] direct: error จาก Kong แสดงตาม error mapping 6 แบบ · pr: error จาก git/decK แสดงข้อความของมันเอง
- [ ] "ซ้อนกัน" = host ทับกัน (ว่าง = ทุก host, `*.x` = wildcard) และ method ทับกัน และ path ซ้ำหรือเป็น prefix
      ของกัน · path regex (`~`) แจ้งว่า "ตรวจไม่ได้" · เป็นคำเตือน ไม่ block
- [ ] ผ่านเกณฑ์ของ R3

## นอก scope
- สร้างหลายรายการพร้อมกันจากไฟล์ (bulk import)
- แก้ไขและลบ — มีอยู่แล้วผ่าน JSON editor ของทุก type

## ตัดสินแล้ว
- service อยู่ใน M1, route อยู่ใน M3
- (คำถามค้าง 1) MCP สร้างได้ (มีอยู่แล้ว) ตามกฎ PR mode/changeset
- (คำถามค้าง 2) ไม่มีค่าตั้งต้นต่อ project
- (คำถามค้าง 3) ไม่ทำ promote
