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
- [ ] แต่ละ env กำหนด `rank` และ `apply_mode` ได้
- [ ] env ที่ยังไม่ได้กำหนด `apply_mode` ต้องไม่ถูกตีความเป็น `direct`
- [ ] header แสดง project + env + สีประจำ connection ตลอดเวลา และสลับ env ภายใน project ได้ในคลิกเดียว
- [ ] `config/connections.yml` รองรับ project/env โดยยังไม่มี secret ในไฟล์
- [ ] `connections.yml` และข้อมูลในเครื่องแบบเดิมย้ายมาได้โดยไม่ต้องกรอก credential ใหม่
- [ ] MCP ยังต้องระบุ connection ชัดเจน และชื่อที่ใช้อ้างไม่กำกวมเมื่อมีหลาย project
- [ ] migration reversible

## นอก scope
- สิทธิ์ต่อ project (Kongsole ไม่มีฐานข้อมูลผู้ใช้)

## ตัดสินแล้ว (จาก docs/DESIGN.md)
- 1 connection = 1 Kong box มี env, rank, color_tag, apply_mode, git config, TLS settings
- rank 0 (dev) ถึง 3 (prod)
- registry อยู่ใน git ของทีม credential อยู่ใน DB ในเครื่องของแต่ละคน

## คำถามค้าง
1. rank มี 4 ระดับ แต่ ProjectA มี 6 env — pt และ ps อยู่ rank ไหน
2. `apply_mode` ของแต่ละ env ของ ProjectA และ ProjectX
3. หนึ่ง env มี Kong หลาย node (หลาย connection) ได้ไหม ถ้าได้ แสดงอย่างไร
4. แต่ละ project ใช้ config repo ของ decK แยกกัน หรือ repo เดียว
5. สีประจำ connection กำหนดต่อ env หรือต่อ rank

## ตัวอย่างประกอบ (ไม่ใช่ schema ที่ตัดสินแล้ว)
```yaml
projects:
  project-a:
    envs: [dev, sit, uat, pt, ps, prod]
  project-x:
    envs: [nonprod, pt, prod]
```
