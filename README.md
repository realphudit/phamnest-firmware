# phamnest-firmware — คลังเฟิร์มแวร์ OTA ของระบบควบคุมบ่อผำ (ผำ-เนสท์)

รีโปนี้เก็บแค่ 2 ไฟล์ที่บอร์ด ESP32-S3 ดึงไปใช้ผ่าน GitHub raw URL:
- `https://raw.githubusercontent.com/<USER>/phamnest-firmware/main/firmware.json` — manifest (เลขเวอร์ชัน + ลิงก์ .bin + โน้ต)
- `https://raw.githubusercontent.com/<USER>/phamnest-firmware/main/firmware.bin` — ตัวเฟิร์มแวร์

## ขั้นตอนปล่อยเวอร์ชันใหม่ (4 ขั้น)
1. เพิ่มเลข `FW_VERSION` (และ `FW_VERSION_STR`) ใน `C:\PhamNest\Firmware_PhamNest\src\config.h`
2. แฟลชทดสอบบนบอร์ดสำรอง (bench board) ให้บูตและทำงานปกติก่อน
3. รัน `.\release.ps1 -Notes "สรุปสิ่งที่เปลี่ยน"` (build → คัดลอก .bin → เขียน manifest → commit → push)
4. รอข้อความ LINE จากบอร์ดยืนยันว่าอัปเดตสำเร็จ (ภายใน 6 ชม. หรือกด "ตรวจอัปเดตเดี๋ยวนี้" ในหน้าเว็บ)

## กฎข้อเดียว
**ห้าม push ไฟล์ .bin ที่ยังไม่เคยบูตบนบอร์ดจริงเด็ดขาด** — บอร์ดหน้างานจะดึงไปติดตั้งเองโดยอัตโนมัติ
