# R1 — หลาย project หลาย environment

## ปัญหา
หน้า connections ไม่รองรับว่าแต่ละ project มีชุด env ต่างกัน
- ProjectA: dev, sit, uat, pt, ps, prod
- ProjectX: nonprod, pt, prod

ผู้ใช้ไม่เห็นว่า connection ไหนเป็น env ไหนของ project ไหน และเสี่ยงทำงานผิด env

## ผู้ใช้และสถานการณ์
Engineer ที่ดูแลหลาย project สลับไปมาในวันเดียว และคนใหม่ที่ยังจำไม่ได้ว่า project ไหนมี env อะไร

## สิ่งที่ต้องการ
- จัด connection เป็นกลุ่มตาม project
- แต่ละ project กำหนดชุด env และลำดับของตัวเองได้
- รู้เสมอว่ากำลังทำงานกับ project/env ไหน

## เกณฑ์ยอมรับ (ร่าง)
- [ ] สร้าง project และกำหนดรายการ env พร้อมลำดับได้ ทดสอบด้วยชุด env ของ ProjectA และ ProjectX ข้างต้น
- [ ] ทุก connection ผูกกับ project และ env เดียว
- [ ] env ที่ `apply_mode = pr` กำหนดได้เฉพาะใน `config/connections.yml` (ต้องมี git)
      env ที่เป็น direct สร้างและแก้ใน UI ได้ · UI ไม่มีทางตั้งหรือถอด `pr`
- [ ] connection ที่สร้างใน UI อยู่ใน DB ของเครื่องนั้นเท่านั้น และมีป้าย "Local only"
      connection จาก `connections.yml` แก้ใน UI ไม่ได้
- [ ] ชื่อ env ตั้งเองได้ต่อ project · ชื่อ dev/sit/uat/prod ได้ rank 0/1/2/3 อัตโนมัติ
      ชื่ออื่นแสดงเป็น "other" และต้องเลือก rank 0–3 เอง ไม่มีค่า default
- [ ] หนึ่ง env มีหนึ่ง connection
- [ ] project มี `network_note` (เช่น ต้องต่อ VPN ไหน) แสดงต่อท้าย error เครือข่าย และสถานะ connection
      แยก "unreachable" (เข้า network ไม่ได้) จาก "unavailable" (Kong ตอบ 502/503)
- [ ] env ที่ยังไม่ได้กำหนด `apply_mode` ต้องไม่ถูกตีความเป็น `direct`
- [ ] header แสดง project + env + สีประจำ connection ตลอดเวลา และ switcher แสดง env ของ project
      ตามลำดับ คลิกแล้วไปหน้า login ของ env นั้น (login ใหม่ทุกครั้งที่สลับ)
- [ ] `config/connections.yml` รองรับ project/env โดยยังไม่มี secret ในไฟล์
- [ ] `connections.yml` และข้อมูลในเครื่องแบบเดิมย้ายมาได้โดยไม่ต้องกรอก credential ใหม่
- [ ] MCP อ้าง connection ด้วย `project/env` เท่านั้น
- [ ] migration reversible

## นอก scope
- สิทธิ์ต่อ project (Kongsole ไม่มีฐานข้อมูลผู้ใช้)

## ตัดสินแล้ว (จาก docs/DESIGN.md)
- 1 connection = 1 Kong box มี env, rank, color_tag, apply_mode, git config, TLS settings
- rank 0 (dev) ถึง 3 (prod)
- registry อยู่ใน git ของทีม credential อยู่ใน DB ในเครื่องของแต่ละคน

## ตัดสินแล้ว (จากคำตอบของเจ้าของงาน 2026-09-24)
1. rank ของชื่อ env อื่น (เช่น pt, ps) ผู้ใช้เลือกเอง
2. `apply_mode` ตาม `connections.yml` (pr) / UI (direct)
3. 1 env = 1 node
4. repo แยกต่อ project
5. ความดังของ UI ตาม rank, จุดสีตาม `color_tag` ของ env

## ตัวอย่างประกอบ (ไม่ใช่ schema ที่ตัดสินแล้ว)
```yaml
projects:
  project-a:
    envs: [dev, sit, uat, pt, ps, prod]
  project-x:
    envs: [nonprod, pt, prod]
```
