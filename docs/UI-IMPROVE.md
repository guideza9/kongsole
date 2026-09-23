# Improve UI + Backend (Ruby on Rails Fullstack) ด้วย Superpowers + Impeccable

## เป้าหมายและปัญหา

1. ใช้กับหลายโปรเจคแต่ละโปรเจคมีหลาย environment ต่างกันเช่น ProjectA มี env คือ dev, sit, uat, pt, ps, prod แต่ projectX มี env คือ nonprod, pt, prod เพจ connections ยังไม่ตอบโจทย์เรื่องนี้
2. เพิ่ม feature create service, route
3. ยังใช้ยากสำหรับ มือใหม่ควรมี hint ในการใช้ feature ทุกอย่าง
4. สามารถสร้าง plugins ทั้ง bundle รวมถึง custom-plugins จะโยงกับข้อ 3 ว่าแต่ละ Plugins นั้นก็อยากให้มี hint คร่าวๆของการใช้ plugins หรืออย่างน้อยดึง schema ออกมาว่ามีอะไรบ้าง
5. หาตัวช่วยในการที่จะเข้าใจแต่ละโปรเจค เนื่องด้วยว่าแต่ละ project มี flow ที่ต่างกันมากจะทำอย่างไรให้คนที่เข้ามาใช้รู้เรื่องทั้งหมดของโปรเจค
6. dashboard static ของ request http status, trasaction per request แบบ all และ per route หรือ perservice (ใช้ร่วมกับ File log plguins, มีความกังวลเรื่อง storage ดังนั้นต้องมีการ clear static เป็นประจำ)
7. เพิ่ม feature export config all และสามารถ custom template ก่อน export ได้ด้วย (ต้องคุยเรื่อง template)
8. PR mode สามารถแก้สิ่งที่ต้องการก่อนและเอามารวมกันแล้วกด PR พร้อมครั้งเดียว

## ข้อจำกัด

- ต้องมี migration ถ้าแตะ schema

## แบ่งชั้นความรับผิดชอบ (สำคัญ — ห้ามข้ามชั้น)

- **ชั้น UI (คุมโดย Impeccable):** view/template, CSS, client-side JS/Stimulus,
  microcopy — ใช้คำสั่ง /impeccable เท่านั้น ห้ามแก้ controller/model ใน task ของชั้นนี้
- **ชั้น Backend (คุมโดย TDD ของ Superpowers):** controller, model, migration,
  service object, serializer — ต้องเขียน test (RED) ก่อนแก้โค้ด (GREEN) แล้ว refactor
  ห้ามแก้ view เกินกว่าที่จำเป็นเพื่อ render field ใหม่

## Contract ระหว่างสองชั้น (ทำก่อนแตก plan)

ถ้า UI ต้องใช้ข้อมูล/field ใหม่ ให้ระบุที่นี่ก่อนเริ่มแก้จริง:

- [เช่น: controller ต้อง expose @overtime_requests.pending พร้อม field `hours_remaining`]

## กระบวนการ

### ขั้น 1 — brainstorming (Superpowers)

- อ่าน PRODUCT.md, DESIGN.md (ถ้ามี), section ปัญหาที่พบข้างต้น
- รัน /impeccable critique + audit กับ view ของแต่ละ surface
- ตรวจโค้ด backend ที่เกี่ยวข้อง (controller/model) หาปัญหาความสอดคล้องกับ UI
  ที่ต้องการ เช่น data ที่ยังไม่มี, N+1, validation ที่ขัดกับ UX ใหม่
- เสนอ "contract" ระหว่าง UI กับ backend ให้ฉันยืนยันก่อนไปขั้นต่อไป

### ขั้น 2 — writing-plans (Superpowers)

- แตก task แยกชั้นชัดเจน โดย **backend task ต้องอยู่ก่อน UI task ที่พึ่งพามัน**
- Backend task ต้องระบุ: ไฟล์ที่แก้, test ที่ต้องเขียนก่อน (RED), เกณฑ์ผ่าน (GREEN)
- UI task ต้องระบุ: คำสั่ง /impeccable ที่ใช้, ไฟล์ที่แก้ได้ (เฉพาะ view/CSS/JS),
  เกณฑ์ตรวจด้วย detect, และอ้างอิงว่าพึ่ง backend task ไหน

### ขั้น 3 — subagent-driven-development (Superpowers)

- git worktree แยก
- รัน backend task ให้เสร็จและ test ผ่านก่อน แล้วค่อยรัน UI task ที่พึ่งพา
- subagent ฝั่ง UI ห้ามแก้ controller/model/migration
- subagent ฝั่ง backend ห้ามแก้ view เกินกว่าที่ contract ระบุ
- review ทุก task แยกตามชั้น (code review ปกติสำหรับ backend, เทียบ DESIGN.md
  สำหรับ UI)

### ขั้น 4 — verification-before-completion (Superpowers)

- Backend: รัน test suite ทั้งหมดที่เกี่ยวข้อง (RSpec/Minitest) ต้องผ่าน
- UI: npx impeccable detect + audit ซ้ำ เทียบ baseline, แนบภาพหน้าจอ
- ตรวจ integration จริง: เปิดหน้าที่แก้ทั้งหมด กดใช้งาน flow จริงว่า
  UI กับ backend เข้ากันตามที่ contract กำหนด
- ถ้ามี migration: สรุปว่า reversible ไหม พร้อม rollback plan สำหรับ CAB

## ตารางอาการ → คำสั่ง Impeccable (อ้างอิงให้ subagent เลือกเอง)

| อาการ | คำสั่ง |
| --- | --- |
| จัดวางรก ช่องไฟไม่สม่ำเสมอ | layout |
| ลำดับความสำคัญของตัวอักษรไม่ชัด | typeset |
| จืด ไม่มีจุดเด่น | bolder, colorize |
| ฉูดฉาดเกินไป | quieter |
| ซับซ้อนเกินจำเป็น | distill |
| ข้อความ/error/ปุ่มสื่อสารไม่ชัด | clarify |
| พังเมื่อข้อความยาว/ข้อมูลว่าง/หลายภาษา | harden |
| ใช้มือถือยาก | adapt |
| ผู้ใช้ใหม่งง ไม่มี empty state | onboard |
| ต้องการ motion มีความหมาย | animate |
| โหลดช้า | optimize |
| จบงาน จัดระบบ | extract, polish |
