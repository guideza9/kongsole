# Improve UI ด้วย Superpowers + Impeccable

## เป้าหมาย

1. หน้า connections ช่วยออกแบบสำหรับหลายโปรเจค แต่ละโปรเจคจะมี env ได้หลากหลายเช่น project A มี env คือ dev, sit , uat, pt, ps, prod และ project X มี env คือ nonprod, pt, prod

[ผลลัพธ์ที่อยากได้ วัดผลได้ถ้าเป็นไปได้
 เช่น "ลดเวลากรอกฟอร์ม Overtime ให้เสร็จใน 3 ขั้นตอน" หรือ
 "ให้หน้า Dashboard ดูเป็นมืออาชีพขึ้น ไม่ใช่ AI slop"]

## Surface ที่จะแก้ (ระบุให้ตรงกับ path จริง)

1. [ชื่อหน้า/flow] — path: src/pages/xxx
2. [ชื่อหน้า/flow] — path: src/pages/yyy

## ปัญหาที่พบ (ต่อ surface)

### [Surface 1]

- อาการ: [สิ่งที่เห็น ไม่ใช่วิธีแก้]
- หลักฐาน: [ภาพ/feedback ถ้ามี — แนบไฟล์หรือบอก path]
- ความสำคัญ: สูง/กลาง/ต่ำ

### [Surface 2]

- อาการ: ...

## ข้อจำกัด (สำคัญมาก ถ้าไม่ระบุ AI จะแก้เกินขอบเขต)

- ห้ามเปลี่ยน: [สีแบรนด์ / ฟอนต์ / โครงสร้าง route / API / library]
- ต้องรองรับ: [ภาษาไทย / มือถือ / dark mode / accessibility ระดับไหน]
- แก้ได้เฉพาะโฟลเดอร์: [path]
- Stack: [React/Rails/Vue/... + เวอร์ชัน UI library ถ้ามี]
- Environment: [dev server รันที่ localhost:xxxx / ยังไม่มี dev server]

## กระบวนการที่ต้องใช้

### ขั้น 0 — เตรียมบริบท (ถ้ายังไม่เคยทำ)

- รัน /impeccable init ถ้ายังไม่มี PRODUCT.md
- รัน /impeccable document ถ้ายังไม่มี DESIGN.md

### ขั้น 1 — brainstorming (Superpowers)

- อ่าน PRODUCT.md, DESIGN.md และ section "ปัญหาที่พบ" ข้างต้น
- รัน /impeccable critique + /impeccable audit กับแต่ละ surface ที่ระบุ
- เทียบผลกับปัญหาที่ฉันเล่า: ยืนยันได้ข้อไหน ไม่เจอข้อไหน
  พบปัญหาใหม่อะไรที่ฉันไม่ได้พูดถึง
- เสนอ scope และลำดับความสำคัญ ถามฉันก่อนไปขั้นต่อไป

### ขั้น 2 — writing-plans (Superpowers)

- แตกเป็น task ต่อ surface งานละ 2-5 นาที
- ทุก task ต้องระบุ:
  - คำสั่ง /impeccable ที่ใช้ (เทียบตารางด้านล่าง)
  - ไฟล์ที่แก้ได้ (ตาม "แก้ได้เฉพาะโฟลเดอร์" ด้านบน)
  - เกณฑ์ตรวจสอบ: npx impeccable detect <target> ต้องไม่มี finding หลัก

### ขั้น 3 — subagent-driven-development (Superpowers)

- ทำงานใน git worktree แยก ไม่แตะ main branch
- แต่ละ task ให้ subagent ใหม่ทำ พร้อม review หลังทุก task
- subagent ต้องอ่าน PRODUCT.md/DESIGN.md ก่อนเริ่ม task ที่แตะ UI

### ขั้น 4 — verification-before-completion (Superpowers)

- รัน npx impeccable detect และ audit ซ้ำ เทียบ baseline จากขั้น 1
- แนบภาพหน้าจอ [ขนาดที่ต้องเช็ค เช่น 375px, 768px, 1280px]
- สรุปว่า finding ไหนแก้แล้ว ไหนเหลือ และทำไม

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
