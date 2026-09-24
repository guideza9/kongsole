# R4 — Plugins (ที่มากับ Kong และ custom) พร้อม hint และ schema

## ปัญหา
ยังสร้าง plugin ไม่ได้ และไม่รู้ว่าแต่ละ plugin มี config อะไรบ้าง โดยเฉพาะ custom plugin ของทีม

## ผู้ใช้และสถานการณ์
Engineer ที่ต้องเพิ่ม auth, rate limiting หรือ custom plugin ให้ service/route

## สิ่งที่ต้องการ
สร้าง plugin ได้ทั้งแบบที่มากับ Kong และ custom โดยอย่างน้อยเห็น schema ว่ามี field อะไร

## เกณฑ์ยอมรับ (ร่าง)
- [ ] รายการ plugin มาจาก `GET /` → `plugins.available_on_server` ของ connection นั้น (ไม่ใช่ `enabled_in_cluster`)
      รวม custom plugin · plugin ที่ไม่ได้โหลดบน node ไม่แสดง
- [ ] custom plugin: คำอธิบายจาก `config/custom_plugins/<name>.yml` ถ้าไม่มี บอกชัดว่าไม่มี
- [ ] เตือนเมื่อ schema ของ plugin เดียวกันต่างจาก env อื่นใน project เดียวกัน
- [ ] ฟอร์มสร้างจาก `GET /schemas/plugins/{name}` ของ connection นั้น: type, required, default, enum, field ซ้อนกัน
- [ ] field ที่ schema ระบุว่าเป็นความลับหรือรองรับ reference แสดงแบบ mask และแนะนำให้ใช้ `{vault://env/...}`
- [ ] ค่าที่เป็นความลับผ่าน redactor ก่อนเข้า read-model และไม่แสดงกลับใน UI หรือ MCP
- [ ] เลือก scope ได้: global / service / route / consumer
- [ ] plugin ที่มากับ Kong มีคำอธิบายสั้น custom plugin แสดงคำอธิบายเท่าที่มี หรือบอกชัดว่าไม่มี
- [ ] plugin บน entity ที่เป็น admin path อยู่ใต้กฎ AdminPathGuard
- [ ] `apply_mode = pr` เข้า changeset (R8)
- [ ] ผ่านเกณฑ์ของ R3

## นอก scope
- การพัฒนาหรือติดตั้ง custom plugin ลง Kong

## ตัดสินแล้ว
- plugins อยู่ใน M4
- Kong CE ใช้ได้เฉพาะ vault backend `env`

## คำถามค้าง
1. คำอธิบายของ custom plugin มาจากไหน (README ใน repo ของ plugin, ไฟล์ metadata ใน Kongsole, ฯลฯ)
2. แสดง plugin ที่มากับ Kong แต่ไม่ได้เปิดใช้บน node นั้นไหม
3. schema ของ plugin เดียวกันต่างกันระหว่าง connection (คนละเวอร์ชัน) ต้องเตือนไหม
