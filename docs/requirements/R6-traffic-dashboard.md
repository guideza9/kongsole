# R6 — Dashboard สถิติ

## ปัญหา
ไม่มีที่ดูสถิติ request ของ Kong แยกตาม service และ route

## ผู้ใช้และสถานการณ์
Engineer ที่ต้องดูว่า API ไหนมี error เพิ่ม หรือ traffic ผิดปกติ

## สิ่งที่ต้องการ
- จำนวน request แยกตาม HTTP status
- request ต่อวินาที (TPS) และจำนวน request
- ดูได้ทั้งแบบรวม ต่อ service และต่อ route
- ใช้ metric จาก Kong Prometheus plugin ผ่าน Prometheus ขององค์กร Kongsole ไม่เก็บ log หรือ metric เอง

## เกณฑ์ยอมรับ (ร่าง)
- [ ] เลือก project, env, connection และช่วงเวลาได้
- [ ] แสดงจำนวน request ตามกลุ่ม status (2xx/3xx/4xx/5xx) และตาม status code
- [ ] แสดง TPS และจำนวน request ทั้งแบบรวม ต่อ service และต่อ route
- [ ] Kongsole ไม่เขียน metric หรือ log ลงดิสก์ และไม่ส่ง credential ให้ Prometheus · ถ้า Prometheus ตอบ 401/403
      แสดงคำอธิบาย แล้วเพิ่ม credential เป็นงานแยก
- [ ] ไม่ต้อง login · Prometheus ของแต่ละ project อาจอยู่คนละ network: หน้าโหลดทันที ข้อมูลโหลดแยกต่อ env
      และบอกชนิดปัญหาเครือข่ายพร้อม `network_note` ของ project ภายใน ~10 วินาที
- [ ] แต่ละ connection แสดง preflight: มี prometheus plugin ไหม, scope, `status_code_metrics` เปิดไหม
      ถ้าไม่พร้อม บอกวิธีแก้ (แก้ plugin ผ่าน R4 → direct หรือ changeset)
- [ ] ผ่านเกณฑ์ของ R3

## นอก scope
- latency percentile, alert, การแจ้งเตือน (เว้นแต่ตัดสินให้เพิ่ม)

## ข้อควรพิจารณา (ให้ AI ประเมินในขั้น brainstorming)
- Kong ทำงานแบบ hybrid: File Log plugin เขียนไฟล์ลงดิสก์ของ data plane pod
  ส่วน Kongsole รันในเครื่องผ่าน port-forward จึงอ่านไฟล์นั้นตรงๆ ไม่ได้ ต้องมีทางนำ log ออกมา
- log ของ Kong มี request header รวมถึง `Authorization`
- การเพิ่ม plugin ใน env ที่ `apply_mode = pr` ต้องผ่าน PR และ CAB
- ทางเลือกที่ควรเทียบกับ File Log:
  - HTTP Log plugin ส่งไปยังตัวรับ
  - Prometheus plugin ที่มากับ Kong CE (ให้ metric ต่อ service/route โดยไม่ต้องเก็บ raw log — ตรวจตามเวอร์ชัน Kong)
  - pipeline log ที่องค์กรมีอยู่แล้ว

## ตัดสินแล้ว
ใช้ Prometheus plugin (มีอยู่แล้วทุก project) + Prometheus ขององค์กร (query PromQL) ทุก env

## คำถามค้าง (เดิม — ตอบแล้วตามส่วน "ตัดสินแล้ว")
1. ค่า N และ M
2. ต้องการใน env ไหนบ้าง และยอมให้เพิ่ม plugin บน prod หรือไม่
3. มี pipeline log หรือ monitoring ขององค์กรที่ต้องใช้ร่วมหรือห้ามซ้ำหรือไม่
4. ถ้าทางเลือกอื่นดีกว่า File Log ยังต้องใช้ File Log อยู่ไหม
