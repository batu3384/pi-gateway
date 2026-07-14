# SSD Boot Gecisi - Raspberry Pi 4B

Bu rehber, yazilim kurulumundan ONCE yapilir.

## Dogru mimari

```
ONCE (yanlis uzun vadede):
  Pi -> SD kart (OS + veri) + SSD takili ama kullanilmiyor

SONRA (dogru):
  Pi -> SSD (OS + Docker + tum veri)
  SD kart -> cikarilir veya sadece recovery yedegi olarak saklanir
```

Evet: **isletim sistemi dahil her seyin SSD uzerinde olmasi** dogru mimari.

---

## Iki yol

| | Yol A: Klonla | Yol B: Sifirdan SSD'ye yaz (ONERILEN) |
|--|---------------|--------------------------------------|
| Ne yapar | SD'deki sistemi SSD'ye kopyalar | Imager ile temiz OS SSD'ye |
| Sure | 15-30 dk | 10 dk |
| Avantaj | Mevcut ayarlar korunur | Temiz, hatasiz, tam 128GB |
| Dezavantaj | Clone hatalari olabilir | SD'deki ayarlari yeniden yaparsin |
| Bizim proje icin | Gerek yok | **En iyi secim** (henuz pi-gateway kurulmadi) |

**Senin durumun:** SD'de sadece temel Pi OS var, pi-gateway henuz yok.
-> **Yol B: SSD'ye sifirdan Raspberry Pi OS yaz.**

---

## Adim adim (Yol B - Onerilen)

### 1. Mac'te Raspberry Pi Imager indir
https://www.raspberrypi.com/software/

### 2. SSD'yi Mac'e tak (USB kablo ile)

### 3. Imager ayarlari
- **OS:** Raspberry Pi OS (64-bit) — **Desktop (tam sürüm)** veya Lite
  - Desktop: monitör/klavye ile kolay kurulum, SD Card Copier, tarayıcı
  - Lite: sadece sunucu, daha az RAM (~400 MB tasarruf)
  - 4 GB RAM ile Desktop + DNS stack rahat çalışır; tam kurulum istiyorsan Desktop seç
- **Depolama:** SSD'yi sec (128GB)
- Dişli ikon (Advanced):
  - Hostname: `pi-gateway`
  - SSH: Enable
  - Username: `pi`
  - Password: guclu sifre
  - Wi-Fi: istege bagli (ethernet kullanacaksan gerek yok)
  - Locale: Turkey / Europe/Istanbul

### 4. Yaz ve bekle (~5-10 dk)

### 5. SSD'yi Pi'ye tak
- **Mavi USB 3.0 port** kullan (USB 2.0 degil)
- SD karti **cikar** (ilk test icin)
- Ethernet + 5V/3A guc

### 6. Ac
- Pi SSD'den boot etmeli
- Acilmazsa: SD'yi geri tak, asagidaki EEPROM adimini yap

---

## EEPROM guncelleme (SSD boot calismazsa)

SD kart takili, Pi acikken SSH ile:

```bash
sudo apt update && sudo apt full-upgrade -y
sudo apt install rpi-eeprom -y
sudo rpi-eeprom-update -a
sudo reboot
```

Boot sirasini USB oncelikli yap:

```bash
sudo raspi-config
# Advanced Options -> Boot Order -> USB Boot
sudo reboot
```

Veya:

```bash
sudo rpi-eeprom-config
# BOOT_ORDER=0xf14 olmali (once USB, sonra SD)
```

`0xf14` = once USB dene, olmazsa SD.

---

## SSD'den boot dogrulama

```bash
lsblk
# root / icinde sda veya nvme gormelisin, mmcblk0 degil

df -h /
# /dev/sda2 veya benzeri olmali

sudo reboot
# SD cikik halde acilmali
```

---

## SD kart ne olacak?

| Secenek | Ne yap |
|---------|--------|
| **Cikar ve sakla** (onerilen) | Recovery icin 3 ay sonra guncel yedek al |
| **Takili birak** | Pi once SD'ye bakabilir; karisiklik yaratir - onerme |
| **Recovery yedek** | Ayda bir `rpi-clone mmcblk0` ile SD'yi guncelle |

Profesyonel tercih: **SSD tek boot, SD cekmecede yedek.**

---

## Sonraki adim (yazilim)

SSD boot calistiktan sonra Mac'ten:

```bash
cd ~/Documents/raspberrypi
# .env duzenle
make install
```

---

## Sik sorunlar

| Sorun | Cozum |
|-------|-------|
| "SD card not found" ekrani | EEPROM guncelle, BOOT_ORDER=0xf14 |
| SSD gorunuyor ama boot yok | Mavi USB 3.0 port, guc adaptoru 3A |
| Clone sonrasi boot yok | geerlingguy/rpi-clone fork kullan (billw2 degil) |
| Kotu USB kablo | "J Micro" chipset sorunlu; baska kablo dene |
| Yavas | USB 2.0 portuna takmis olabilirsin |

## Kaynaklar

- https://www.raspberrypi.com/documentation/computers/raspberry-pi.html#usb-mass-storage-boot
- https://rpi-clone.jeffgeerling.com/ (klon icin)
- https://raspberry.tips/en/raspberrypi-tutorials/boot-raspberry-pi-from-usb-ssd-flash-drive-pi-4-5
