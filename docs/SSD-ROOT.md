# SD Boot + SSD Rootfs (A mimarisi)

Üretim hedefi: **SD yalnızca boot**, **SSD = rootfs + Docker + veri**.

## Mimari

```
Pi EEPROM → SD bootfs (firmware/kernel/cmdline)
         → cmdline root=PARTUUID=<ssd> → SSD ext4 /
```

| Disk | Rol |
|------|-----|
| SD `bootfs` | firmware, kernel, cmdline, config |
| SSD root | OS, apt, home, Docker, pi-gateway data |

`STORAGE_TYPE=ssd-root` — hybrid (`/mnt/ssd` data-disk) **üretim varsayılanı değil**; JMicron USB ve EEPROM riski nedeniyle deneysel kabul edilir.

## Cutover (Mac)

**Önkoşul:** Restic / `make backup-pull` (veya bilinçli risk kabulü). Pi kapalı. SD + SSD Mac USB'de.

```bash
cd ~/Documents/raspberrypi
# SSD silinir — onay zorunlu
PI_PASSWORD='...' CONFIRM=yes ./scripts/mac/migrate-sd-boot-ssd-root.sh

# Zorunlu dogrulama (false-green yok):
PI_SD_DISK=/dev/diskXX PI_SSD_DISK=/dev/diskYY ./scripts/mac/verify-ssd-root.sh
```

`verify-ssd-root` SD ve SSD bootfs'i **disk kimligiyle** esler; SD `root=` SSD `root=` ile ayni olmali ve eski SD PARTUUID'den farkli olmali. SD'de `resize` + `user-data`/`ssh` zorunlu (firmware SD'den boot eder).

Cutover sonrasi onarim (Mac, diskler takili):
```bash
PI_SD_DISK=/dev/diskXX PI_SSD_DISK=/dev/diskYY ./scripts/mac/repair-cutover-bootfs.sh
```
SD golden kaynak; firmware/kernel/initramfs SD'den SSD'ye snapshot ile kopyalanir. JMicron okuyucuda SSD bootfs bozulursa `STRICT_SSD_BOOTFS=no` (varsayilan) ile verify uyarir — A mimarisinde Pi SD bootfs'ten acilir.

1. SD + SSD'yi Pi'ye tak (SSD → mavi USB 3.0)
2. Aç, ~3–5 dk bekle (resize + cloud-init)
3. SSH: `findmnt -n -o SOURCE /` → **mmcblk olmamalı**
4. `.env`: `STORAGE_TYPE=ssd-root`
5. Mac: `./scripts/mac/deploy.sh`
6. İlk girişte güçlü şifre (`passwd`) + `ssh-copy-id` + PasswordAuthentication kapat
7. Deploy sonrası otomatik: `ssd-root-harden.sh` (EEPROM + root check)
8. Legacy SD root:
   `CONFIRM=yes sudo bash ~/pi-gateway/scripts/pi/neutralize-legacy-sd-root.sh`
   veya deploy sırasında `CONFIRM_NEUTRALIZE=yes`
### EEPROM (gerekirse, eski SD root ile bir kez)

```bash
sudo rpi-eeprom-config --edit
# BOOT_ORDER=0xf41   # SD once, sonra USB
# USB_MSD_PWR_OFF_TIME=0
# USB_MSD_DISCOVER_TIMEOUT=25000
# USB_MSD_STARTUP_DELAY=5000
```

JMicron adaptör: `docs/SSD-JMICRON-FIX.md`.

## Doğrulama

```bash
findmnt -n -o SOURCE,FSTYPE /
# /dev/sdX2  ext4

df -h /
REMOTE_DIR=~/pi-gateway bash ~/pi-gateway/scripts/pi/smoke-test.sh
# root-on-ssd PASS

REMOTE_DIR=~/pi-gateway bash ~/pi-gateway/scripts/pi/reboot-smoke.sh post
```

## Hybrid'den fark

| | hybrid (eski) | ssd-root |
|--|---------------|----------|
| OS | SD | SSD |
| Root RO riski | Yüksek (SD I/O) | Düşük |
| `/mnt/ssd` | Zorunlu data disk | Yok |
| `data/` | symlink | native dizin |
| Docker root | `/mnt/ssd/docker` | `/var/lib/docker` (SSD'de) |

## Alternatif B

Tam USB SSD boot (SD çıkarma): `docs/SSD-KURULUM.md` — bu projenin varsayılanı değil.
