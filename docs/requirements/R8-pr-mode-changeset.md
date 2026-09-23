# R8 — PR mode แบบ changeset

## ปัญหา
การแก้หลายอย่างต้องเปิด PR หลายครั้ง ทำให้ CAB ต้องตรวจหลาย PR และลำดับการ merge สับสน

## ผู้ใช้และสถานการณ์
Engineer ที่เตรียมการเปลี่ยนแปลงสำหรับ uat/prod ซึ่งมักมีหลาย entity ในงานเดียว

## สิ่งที่ต้องการ
แก้หลายรายการสะสมเป็น changeset แล้วเปิด PR ครั้งเดียว

## เกณฑ์ยอมรับ (ร่าง)
- [ ] changeset รวมการสร้าง แก้ และลบ หลาย entity หลายชนิดได้
- [ ] ดู แก้ และลบรายการใน changeset ได้ก่อนส่ง และ changeset ยังอยู่หลังปิด browser
- [ ] preview diff ของ decK YAML ทั้งหมดก่อนเปิด PR
- [ ] block การเปิด PR เมื่อแตะ entity ที่มี tag `kong-admin-path` หรือมีการลบเกินเกณฑ์
- [ ] PR body สรุปรายการเปลี่ยนแปลง และมี trailer `Changed-by:` จาก operator
- [ ] ตรวจก่อนเปิด PR ว่า git หรือ Kong เปลี่ยนไปหลังเริ่ม changeset หรือไม่ และแจ้งให้ชัด
- [ ] หลังเปิด PR แสดงลิงก์และสถานะของ PR
- [ ] YAML ที่ได้ผ่าน parse → serialize แล้วเหมือนเดิมทุก byte
- [ ] ผ่านเกณฑ์ของ R3

## นอก scope
- merge PR หรือรัน `deck gateway sync` จาก Kongsole (เป็นหน้าที่ของ CI หลัง CAB อนุมัติ)

## ตัดสินแล้ว (จาก docs/DESIGN.md)
- PR mode อยู่ใน M2: branch → PR → CAB → merge → CI รัน `deck gateway sync`
- render จาก git, `select_tags` บังคับ, round-trip ต้องตรงทุก byte
- R8 ขยายแนวคิด ChangePlan ที่ออกแบบไว้ ไม่สร้างกลไกใหม่แยก

## คำถามค้าง
1. git host ที่ใช้
2. changeset หนึ่งอันข้ามหลาย env ได้ไหม (เช่น uat และ prod พร้อมกัน) หรือหนึ่ง PR ต่อหนึ่ง env
3. เกณฑ์จำนวนการลบที่ต้อง block
4. connection ที่ `apply_mode = direct` ใช้ changeset ได้ด้วยไหม (เช่น apply หลายรายการครั้งเดียว)
5. MCP สร้างหรือส่ง changeset ได้ไหม
