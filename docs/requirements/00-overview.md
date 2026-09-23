# 00 — ภาพรวม Requirements ของ Kongsole

> เกณฑ์ยอมรับทุกข้อในโฟลเดอร์นี้เป็น **ร่าง** ให้เจ้าของงานแก้ให้ตรงความต้องการก่อนเริ่มวางแผน
> ส่วน "ตัดสินแล้ว" มาจาก `docs/DESIGN.md` ถ้าขัดกัน ให้ `docs/DESIGN.md` ชนะ และให้ AI รายงาน

## เป้าหมาย
ทำให้ Kongsole
1. ใช้ได้กับหลายโปรเจกต์ที่มีชุด environment ไม่เหมือนกัน
2. คนที่เพิ่งเข้าทีมใช้ได้เองโดยไม่ต้องมีคนสอน
3. ครอบคลุมงานประจำที่ยังขาด: สร้าง entity, จัดการ plugin, ดูสถิติ, export, รวมการแก้เป็น PR เดียว

## สถานะของโค้ด
บาง requirement อาจยังไม่มีหน้าจอให้ "ปรับปรุง" ในขั้น brainstorming ให้ AI รายงานว่า
หน้าไหนมีแล้ว หน้าไหนยังไม่มี และถ้ายังไม่มี ให้เสนอว่าควรผนวกเข้า milestone ใดใน `docs/DESIGN.md`

## คำศัพท์ (ใช้คำเหล่านี้เท่านั้น)
| คำ | ความหมาย |
| --- | --- |
| Project | กลุ่มของ connection ที่เป็นระบบเดียวกัน (แนวคิดใหม่ใน R1) |
| Environment (env) | ชื่อ env ที่แต่ละ project กำหนดเอง เช่น `sit`, `ps`, `nonprod` |
| Connection | Kong box หนึ่งตัว = หนึ่งแถวใน `kong_connections` |
| rank | ระดับความเสี่ยงของ connection: 0 (dev) ถึง 3 (prod) |
| apply_mode | `direct` = เขียน Admin API / `pr` = เปิด PR ของ decK YAML |
| Changeset | ชุดการเปลี่ยนแปลงที่สะสมไว้เพื่อส่งเป็น PR เดียว (R8) |
| Hint | ข้อความช่วยเหลือใน UI: คำอธิบาย field, empty state, คำเตือนผลกระทบ (R3) |
| Surface | หน้าหรือ flow หนึ่งหน้าที่ Impeccable ทำงานด้วย |

## Requirements
| ID | ชื่อ | ความสำคัญ (ร่าง) | milestone ที่เกี่ยว |
| --- | --- | --- | --- |
| R1 | หลาย project หลาย env | สูง | M0 (connections) |
| R2 | สร้าง service และ route | สูง | M1 (service), M3 (route) |
| R3 | Hint สำหรับมือใหม่ | สูง (ทำคู่กับทุก feature) | ทุก milestone |
| R4 | Plugins + schema | สูง | M4 |
| R5 | ช่วยให้เข้าใจแต่ละ project | กลาง | ใหม่ |
| R6 | Dashboard สถิติ | กลาง | ใหม่ |
| R7 | Export config + template | กลาง | ใหม่ |
| R8 | PR mode แบบ changeset | สูง | M2 |

## การพึ่งพา (ให้ AI ตรวจและเติม)
- R1 เป็นฐานของ R2, R5, R6, R7, R8 เพราะทุกข้อต้องรู้ว่ากำลังทำงานกับ project/env ไหน
- R8 ต้องมีก่อน R2 และ R4 จะเขียนลง connection ที่ `apply_mode = pr` ได้
- R3 ไม่ใช่ feature แยก เกณฑ์ของ R3 ใช้กับหน้าที่สร้างใน requirement อื่นทุกหน้า
  แต่ส่วนโครงสร้างกลาง (ที่เก็บข้อความ hint, การปิด hint) ทำเป็น task ของ R3 เอง

## เกณฑ์ที่ใช้กับทุก requirement
- [ ] ทุกหน้าที่สร้างหรือแก้ผ่านเกณฑ์ของ R3
- [ ] ไม่ละเมิดกฎใน CLAUDE.md (credential, admin path, apply_mode)
- [ ] ข้อความทั้งหมดรองรับภาษาไทยโดยไม่ล้นหรือตัดคำผิด
- [ ] test ของ backend ผ่านทั้งหมด และ `npx impeccable detect` ไม่มี finding หลักบนหน้าที่แก้
- [ ] เปิดหน้าจริงและกดใช้ flow จริงกับ compose ในเครื่องแล้ว

## นอก scope ของรอบนี้
- ระบบผู้ใช้และสิทธิ์ของ Kongsole เอง (login คือ credential ของ Kong ตามที่ออกแบบไว้)
- การ deploy Kongsole เป็น service กลาง
- การรองรับ Kong Enterprise
