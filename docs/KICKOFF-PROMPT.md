อ่าน CLAUDE.md, docs/DESIGN.md, PRODUCT.md และไฟล์ design system ของ Impeccable (ถ้ามี)
และทุกไฟล์ใน docs/requirements/ ก่อนเริ่ม

# ช่วงที่ 1: วางแผน (อ่านอย่างเดียว)
ห้ามแก้โค้ด ห้ามสร้าง migration ห้ามรัน /impeccable ที่แก้ไฟล์ ห้ามเรียก Admin API แบบเขียน
ทำได้เพียง: อ่านโค้ด, รัน /impeccable critique / audit, npx impeccable detect,
รัน test เดิมเพื่อดู baseline, เขียนไฟล์ใน docs/plans/
ถ้ายังไม่มี PRODUCT.md หรือ design system ของ Impeccable ให้ถามก่อนรัน init/document

## ขั้นที่ 1 — brainstorming
1. เล่าเกณฑ์ยอมรับของแต่ละ requirement กลับมาด้วยคำของคุณ
2. ชี้จุดที่คลุมเครือ ขัดกันเอง ตรวจไม่ได้ หรือขัดกับ docs/DESIGN.md
3. รายงานว่าหน้าไหนมีแล้ว หน้าไหนยังไม่มี และควรผนวกเข้า milestone ใด
4. critique + audit หน้าที่มีอยู่แล้ว
5. เรื่องที่ requirement ขอให้เสนอทางเลือก ให้เสนอ 2-3 ทางพร้อมข้อดีข้อเสีย
6. รวมคำถามค้างทั้งหมดถามฉันเป็นชุดเดียว เรียงตามผลกระทบ แล้วรอคำตอบ
ถ้าคำตอบของฉันเปลี่ยน requirement ให้เสนอข้อความที่จะแก้ในไฟล์ requirement ด้วย

## ขั้นที่ 2 — writing-plans
- docs/plans/00-roadmap.md: สรุปหน้าเดียว, ลำดับ requirement พร้อมเหตุผลและการพึ่งพา,
  baseline, migration ทั้งหมดพร้อม rollback, การตัดสินใจจากคำตอบของฉัน, ความเสี่ยง
- docs/plans/R1-...md ถึง R8-...md: spec ที่ตกลงแล้ว, contract UI ↔ backend,
  task ครบทุกตัว (ห้ามเขียนคร่าวๆ สำหรับ requirement หลังๆ), เกณฑ์ปิดงาน
- ทุก task ระบุ: ชั้น (UI/backend), task ที่ต้องเสร็จก่อน, ไฟล์ที่แก้ได้,
  backend = test ที่เขียนก่อนและเกณฑ์ผ่าน, UI = คำสั่ง /impeccable และเกณฑ์ detect, checkbox [ ]

## 🛑 จุดหยุดบังคับ
เขียน plan ครบแล้วให้หยุด แสดงสรุป roadmap และคำถามที่ยังเหลือ
ห้ามสร้าง worktree ห้ามเริ่ม subagent ห้ามแก้โค้ด จนกว่าฉันจะพิมพ์ว่า "อนุมัติ plan"

# ช่วงที่ 2: ลงมือ (หลังอนุมัติเท่านั้น)
- สร้าง worktree แยก บันทึก path ใน 00-roadmap.md
- ทำทีละ requirement ตามลำดับ roadmap / backend ผ่าน test ก่อน UI ที่พึ่งพา
- แก้เฉพาะไฟล์ที่ task ระบุ ไม่ข้ามชั้น
- ถ้า plan ผิดหรือต้องเพิ่ม task ให้หยุดถาม ห้ามแก้ plan เอง
- commit ทีละ task อ้างเลข task และอัปเดต checkbox
- จบแต่ละ requirement ให้หยุดรายงานก่อนเริ่มข้อถัดไป

## verification-before-completion
ตรวจตามเกณฑ์ยอมรับของ requirement และเกณฑ์กลางใน 00-overview.md
แนบผล test, ผล detect/audit เทียบ baseline, ภาพหน้าจอ และยืนยันว่าไม่มี credential หลุด

## Resume
ถ้าเริ่ม session ใหม่ ให้อ่าน 00-roadmap.md และ plan ที่ค้าง เทียบ git log กับ checkbox ก่อนทำต่อ
