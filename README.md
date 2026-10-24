# Chained Beasts ภาษาไทย | Thai Translation Mod

[![Chained Beasts](https://shared.akamai.steamstatic.com/store_item_assets/steam/apps/3569420/be237edbd1bdbcf361d7b315d70e89fea3b5262a/header.jpg?t=1792711697)](https://store.steampowered.com/app/3569420/Chained_Beasts/)

ม็อดภาษาไทยสำหรับ **Chained Beasts บน Steam Windows build 26152147** เวอร์ชันม็อด 1.0.0

A Thai translation mod for Chained Beasts on Steam Windows, with Thai fonts and installation and uninstall instructions.

## [ดาวน์โหลดม็อดภาษาไทย (.zip)](https://github.com/j4cke7/chained-beasts-thai/releases/download/v1.0.0-build26152147/Chained-Beasts-Thai-replace-en-26152147.zip)

[รายละเอียดรุ่น](https://github.com/j4cke7/chained-beasts-thai/releases/tag/v1.0.0-build26152147) · [ไฟล์ตรวจสอบ SHA-256](https://github.com/j4cke7/chained-beasts-thai/releases/download/v1.0.0-build26152147/Chained-Beasts-Thai-replace-en-26152147.zip.sha256)

ดาวน์โหลด ZIP จากลิงก์ข้างบนเพื่อใช้งานม็อด ขนาดไฟล์ 955,061 ไบต์ หรือประมาณ 933 KiB

ม็อดใช้แทนภาษา English ในเกม ภาษาอื่นยังเลือกได้ตามเดิม ข้อความที่ยังไม่ได้แปลจะแสดงเป็นภาษาอังกฤษ ฟอนต์ภาษาไทยรวมอยู่ในชุดม็อดแล้ว ไม่ต้องติดตั้งฟอนต์เพิ่ม

## วิธีติดตั้ง

1. ปิดเกมให้เรียบร้อย
2. แตกไฟล์ ZIP **ทั้งหมด** ไว้ในโฟลเดอร์เดียวกัน เช่น โฟลเดอร์บน Desktop ไม่จำเป็นต้องแตกลงโฟลเดอร์เกม เก็บไฟล์และโฟลเดอร์ย่อยในชุดม็อดไว้ด้วยกัน
3. ดับเบิลคลิก `Install.cmd` แล้วรอให้ติดตั้งเสร็จ ตัวติดตั้งจะค้นหาโฟลเดอร์เกมใน Steam และสำรองไฟล์เดิมโดยอัตโนมัติ
4. เปิดเกม ไปที่ **Settings > Language > English** ข้อความที่แปลไว้จะแสดงเป็นภาษาไทย

ตัวติดตั้งใช้ไฟล์ `.cmd` เรียกสคริปต์ PowerShell คุณอ่าน [ซอร์สโค้ด Patch.ps1](source/Patch.ps1) ได้ก่อนใช้งาน

## วิธีถอนม็อด

1. ปิดเกม
2. ดับเบิลคลิก `Uninstall.cmd` ในโฟลเดอร์ม็อด
3. เปิดเกมอีกครั้ง ภาษา English จะกลับเป็นภาษาอังกฤษ

เก็บโฟลเดอร์ม็อดไว้สำหรับถอนการติดตั้ง และอย่าลบไฟล์สำรองที่ตัวติดตั้งสร้างไว้ในโฟลเดอร์เกม

## หากติดตั้งไม่สำเร็จ

- ตรวจว่าแตกไฟล์ ZIP ครบแล้วและปิดเกมอยู่
- หากการติดตั้งถูกขัดจังหวะ ให้ปิดเกมแล้วเรียก `Install.cmd` อีกครั้ง
- หากขึ้นว่าไม่รองรับรุ่นเกม ให้หยุดติดตั้งและใช้ม็อดที่ตรงกับรุ่นเกม อย่าฝืนติดตั้งข้ามการตรวจรุ่น
- หากแจ้งว่าไฟล์เกมถูกแก้ไขหรือเสียหาย ให้คืนไฟล์ต้นฉบับก่อน ใน Steam คลิกขวาที่เกม แล้วเลือก **Properties > Installed Files > Verify integrity of game files** การตรวจนี้อาจคืนไฟล์ที่ม็อดอื่นแก้ไว้เป็นต้นฉบับด้วย

เมื่อ Steam อัปเดตเกม ม็อดอาจหายหรือใช้ต่อไม่ได้ ให้รอม็อดที่รองรับเกมรุ่นนั้น ชุดนี้รองรับเฉพาะ build 26152147

### เมื่อตัวติดตั้งหาโฟลเดอร์เกมไม่พบ

ทำส่วนนี้เฉพาะเมื่อ `Install.cmd` แจ้งว่าหาเกมไม่พบ

1. ใน Steam คลิกขวาที่ Chained Beasts แล้วเลือก **Manage > Browse local files**
2. คัดลอกพาธจากแถบที่อยู่ของหน้าต่างโฟลเดอร์เกม
3. กลับไปโฟลเดอร์ม็อด คลิกแถบที่อยู่ พิมพ์ `powershell` แล้วกด Enter
4. วางคำสั่งด้านล่าง เปลี่ยนพาธในเครื่องหมายคำพูดเป็นพาธเกมที่คัดลอกมา แล้วกด Enter

```powershell
powershell.exe -NoProfile -ExecutionPolicy Bypass -File .\Patch.ps1 -Action Install -GameRoot "D:\SteamLibrary\steamapps\common\Chained Beasts"
```

## ตรวจสอบไฟล์ดาวน์โหลด

SHA-256 ของ `Chained-Beasts-Thai-replace-en-26152147.zip` คือ

```text
1476bd086748a1a428e4fe2587c13be656c1a3a9246954345b6f79c2bbe1fbaf
```

ใน PowerShell ใช้คำสั่งนี้ โดยเปลี่ยนพาธให้ตรงกับไฟล์ที่ดาวน์โหลด แล้วเทียบค่า `Hash` กับค่าด้านบน

```powershell
Get-FileHash -Algorithm SHA256 -LiteralPath ".\Chained-Beasts-Thai-replace-en-26152147.zip"
```

## ภาพเกม

ภาพโปรโมตจาก[หน้าร้าน Steam ของ Featherweight Games](https://store.steampowered.com/app/3569420/Chained_Beasts/)

![ภาพการเล่น Chained Beasts ภาพที่ 1](https://shared.akamai.steamstatic.com/store_item_assets/steam/apps/3569420/27c1b81a3c373420573c6de9a32218689de6b3ff/ss_27c1b81a3c373420573c6de9a32218689de6b3ff.1920x1080.jpg?t=1792711697)

![ภาพการเล่น Chained Beasts ภาพที่ 2](https://shared.akamai.steamstatic.com/store_item_assets/steam/apps/3569420/11b9af2ff2fa963edb66065a8861cf7d5e1a8d69/ss_11b9af2ff2fa963edb66065a8861cf7d5e1a8d69.1920x1080.jpg?t=1792711697)

## ซอร์สโค้ดและสัญญาอนุญาต

- [Patch.ps1](source/Patch.ps1), [Install.cmd](source/Install.cmd) และ [Uninstall.cmd](source/Uninstall.cmd) เป็นซอร์สโค้ดของตัวติดตั้งและตัวถอนม็อด
- [สัญญาอนุญาตฟอนต์](licenses/) มีข้อกำหนดของฟอนต์ Chakra Petch, Kanit และ Sarabun ที่รวมในชุดม็อด
- [SHA256SUMS.txt](SHA256SUMS.txt) เก็บค่า SHA-256 สำหรับตรวจสอบไฟล์เผยแพร่

ม็อดนี้เป็นงานแปลโดยแฟนเกม ไม่มีส่วนเกี่ยวข้องอย่างเป็นทางการกับผู้พัฒนาหรือผู้จัดจำหน่าย Chained Beasts
