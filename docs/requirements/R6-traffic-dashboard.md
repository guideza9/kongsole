# R6 — Dashboard สถิติ

## ปัญหา
ไม่มีที่ดูสถิติ request ของ Kong แยกตาม service และ route

## ผู้ใช้และสถานการณ์
Engineer ที่ต้องดูว่า API ไหนมี error เพิ่ม หรือ traffic ผิดปกติ

## สิ่งที่ต้องการ
- จำนวน request แยกตาม HTTP status
- request ต่อวินาที (TPS) และจำนวน request
- ดูได้ทั้งแบบรวม ต่อ service และต่อ route
- ใช้ข้อมูลจาก File Log plugin
- ล้างข้อมูลเก่าอัตโนมัติ เพราะกังวลเรื่อง storage

## เกณฑ์ยอมรับ (ร่าง)
- [ ] เลือก project, env, connection และช่วงเวลาได้
- [ ] แสดงจำนวน request ตามกลุ่ม status (2xx/3xx/4xx/5xx) และตาม status code
- [ ] แสดง TPS และจำนวน request ทั้งแบบรวม ต่อ service และต่อ route
- [ ] raw log เก็บไม่เกิน N วัน ข้อมูลสรุปเก็บ M วัน ลบอัตโนมัติ ตั้งค่าได้ และแสดงพื้นที่ที่ใช้อยู่
- [ ] ไม่เก็บ header, cookie, query หรือ body ที่อ่อนไหว (เช่น `Authorization`, `apikey`) — กรองก่อนเขียนลงดิสก์ของ Kongsole และมี test
- [ ] การเก็บ log ไม่ทำให้ latency ของ Kong เพิ่มอย่างมีนัยสำคัญ
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

## คำถามค้าง
1. ค่า N และ M
2. ต้องการใน env ไหนบ้าง และยอมให้เพิ่ม plugin บน prod หรือไม่
3. มี pipeline log หรือ monitoring ขององค์กรที่ต้องใช้ร่วมหรือห้ามซ้ำหรือไม่
4. ถ้าทางเลือกอื่นดีกว่า File Log ยังต้องใช้ File Log อยู่ไหม
