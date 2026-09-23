# Kongsole — กติกาสำหรับ AI

## บริบทของระบบ

- Kongsole คือเครื่องมือจัดการ Kong CE ของทีม รันในเครื่อง เข้า Admin API ผ่าน `basic-auth`
- Backend: Rails 8 ทำหน้าที่ proxy ไป Kong Admin API + Postgres read-model (เป็น index ที่ลบสร้างใหม่ได้)
- Source of truth: git = สิ่งที่ควรเป็น (env ที่ใช้ PR mode) / Kong = สิ่งที่เป็นอยู่ / read-model = index
- สถาปัตยกรรมเต็มอยู่ที่ `docs/DESIGN.md` — อ่านก่อนเสนอการเปลี่ยนแปลงเชิงออกแบบใดๆ
- Frontend (เสนอไว้ รอยืนยัน): Hotwire/Turbo + Stimulus + ViewComponent + Tailwind
- MCP server: TypeScript ใน `mcp/` เรียก backend ของ Kongsole ไม่เรียก Kong ตรง
- Requirement อยู่ที่ `docs/requirements/` / Plan ที่ AI เขียนอยู่ที่ `docs/plans/`

## ไฟล์ชื่อซ้ำ: DESIGN.md

- `docs/DESIGN.md` = สถาปัตยกรรมระบบ (เขียนโดยทีม)
- ไฟล์ design system ที่ `/impeccable document` สร้าง = ภาพและ UI
- ห้ามให้ Impeccable เขียนทับ `docs/DESIGN.md` ถ้าจะเขียนไปที่ path เดียวกันหรือไม่แน่ใจ ให้ถามก่อน

## กฎที่ห้ามละเมิด

1. connection ที่ `apply_mode = pr` ห้ามเขียน Admin API ทุกกรณี ต้องเป็น PR ของ decK YAML เท่านั้น
   รวมถึง import, bulk update, sync และปุ่มลัดทุกชนิด
   (เหตุผล: ทุกการเปลี่ยน uat/prod ต้องมีร่องรอยให้ CAB ตรวจ)
2. Render decK YAML จาก git ไม่ใช่จาก `deck dump` และต้องมี `_info.select_tags` เสมอ
   (เหตุผล: `deck gateway sync` ลบทุกอย่างใน Kong ที่ไม่อยู่ในไฟล์ ถ้าไฟล์ผิดคือ outage)
3. Entity ที่มี tag `kong-admin-path` ห้าม render ลง YAML ห้ามลบผ่าน MCP
   และการลบผ่าน UI ต้องพิมพ์ชื่อ connection ยืนยัน
   (เหตุผล: ถ้าเส้นทาง admin หาย จะไม่มีใครเข้า Admin API ได้ รวมถึง CI)
4. Credential: ห้ามคืนผ่าน API ใดๆ ห้าม log header `Authorization`
   ห้าม render `basicauth_credentials` / `keyauth_credentials` ลง YAML
   ห้าม export เป็น plain text และข้อมูลอ่อนไหวต้องผ่าน redactor ก่อนเข้า read-model
   (เหตุผล: ระบบธนาคาร ผ่านการตรวจของทีม security)
5. MCP ทุก tool ต้องระบุ `connection` ชัดเจน ไม่มีค่า default
6. แตะ schema ต้องมี migration แบบ reversible พร้อมขั้นตอน rollback
7. ระหว่างพัฒนาให้ทดสอบกับ compose ในเครื่องหรือ env ที่ `rank = 0` เท่านั้น

## การแบ่งชั้นความรับผิดชอบ

- **UI (Impeccable):** view, ViewComponent, CSS, Stimulus, microcopy, hint
  ใช้คำสั่ง `/impeccable` ห้ามแก้ controller / model / migration
- **Backend (TDD ของ Superpowers):** controller, model, migration, service object,
  serializer, `Kong::Client`, MCP — เขียน test (RED) ก่อน แก้ให้ผ่าน (GREEN) แล้ว refactor
- **หน้าใหม่:** backend task สร้าง view ตั้งต้นขั้นต่ำให้ใช้งานได้ แล้ว UI task ใช้ `/impeccable` ปรับ
  ห้ามให้ UI task สร้าง logic เอง
- Task เดียวห้ามแตะทั้งสองชั้น ยกเว้นการ render field ใหม่ตาม contract

## คำศัพท์

ดู `docs/requirements/00-overview.md` และใช้คำตามนั้นตลอด ห้ามใช้คำพ้องความหมาย
