# SSD Boot Migration — Raspberry Pi 4B

> **Production default (2026-07):** **Hybrid** — SD = OS root, SSD = data (`/mnt/ssd`)
> Script: `scripts/mac/setup-hybrid.sh` or after cutover `scripts/mac/restore-hybrid-boot.sh`
>
> **Experimental:** [SSD-ROOT.md](SSD-ROOT.md) — SD bootfs + SSD rootfs (JMicron/EEPROM risk)

## Architecture summary

```
Hybrid (recommended, default):
  Pi -> SD (boot + root) + SSD (ext4 /mnt/ssd, Docker + pi-gateway data)

A (ssd-root, experimental):
  Pi -> SD bootfs + SSD rootfs (OS + Docker + data)

B (full USB boot):
  Pi -> SSD (OS + everything), SD removed
```

The remainder of this file covers **B** (full USB SSD boot). For hybrid use `setup-hybrid.sh`; for ssd-root see `SSD-ROOT.md`.

---

## Correct architecture (B — full USB boot)

```
BEFORE (wrong long-term):
  Pi -> SD card (OS + data) + SSD attached but unused

AFTER (B):
  Pi -> SSD (OS + Docker + all data)
  SD card -> removed or kept only as recovery backup
```

---

## Two paths

| | Path A: Clone | Path B: Fresh write to SSD (RECOMMENDED) |
|--|---------------|------------------------------------------|
| What it does | Copies SD system to SSD | Imager writes clean OS to SSD |
| Time | 15–30 min | 10 min |
| Advantage | Keeps existing settings | Clean, error-free, full 128GB |
| Disadvantage | Clone errors possible | Reconfigure SD settings |
| For this project | Not needed | **Best choice** (pi-gateway not installed yet) |

**Typical case:** SD has only base Pi OS, pi-gateway not yet installed.
→ **Path B: Write fresh Raspberry Pi OS to SSD.**

---

## Step by step (Path B — recommended)

### 1. Download Raspberry Pi Imager on Mac
https://www.raspberrypi.com/software/

### 2. Connect SSD to Mac (USB cable)

### 3. Imager settings
- **OS:** Raspberry Pi OS (64-bit) — **Desktop (full)** or Lite
  - Desktop: easier setup with monitor/keyboard, SD Card Copier, browser
  - Lite: server only, less RAM (~400 MB saved)
  - With 4 GB RAM, Desktop + DNS stack runs fine; choose Desktop for full setup
- **Storage:** Select SSD (128GB)
- Gear icon (Advanced):
  - Hostname: `pi-gateway`
  - SSH: Enable
  - Username: `pi`
  - Password: strong password
  - Wi-Fi: optional (not needed if using ethernet)
  - Locale: Turkey / Europe/Istanbul

### 4. Write and wait (~5–10 min)

### 5. Connect SSD to Pi
- Use **blue USB 3.0 port** (not USB 2.0)
- **Remove** SD card (for first test)
- Ethernet + 5V/3A power

### 6. Power on
- Pi should boot from SSD
- If it does not: reinsert SD, follow EEPROM steps below

---

## EEPROM update (if SSD boot fails)

With SD inserted, Pi powered on, over SSH:

```bash
sudo apt update && sudo apt full-upgrade -y
sudo apt install rpi-eeprom -y
sudo rpi-eeprom-update -a
sudo reboot
```

Set boot order USB-first:

```bash
sudo raspi-config
# Advanced Options -> Boot Order -> USB Boot
sudo reboot
```

Or:

```bash
sudo rpi-eeprom-config
# BOOT_ORDER=0xf14 required (USB first, then SD)
```

`0xf14` = try USB first, fall back to SD.

---

## Verify boot from SSD

```bash
lsblk
# root / should show sda or nvme, not mmcblk0

df -h /
# should be /dev/sda2 or similar

sudo reboot
# should boot with SD removed
```

---

## What about the SD card?

| Option | Action |
|--------|--------|
| **Remove and store** (recommended) | Take recovery backup after 3 months |
| **Leave inserted** | Pi may boot SD first; causes confusion — not recommended |
| **Recovery backup** | Monthly `rpi-clone mmcblk0` to refresh SD |

Professional preference: **SSD sole boot, SD in drawer as backup.**

---

## Next step (software)

After SSD boot works, from Mac:

```bash
cd ~/Documents/raspberrypi
# edit .env
make install
```

---

## Common issues

| Issue | Fix |
|-------|-----|
| "SD card not found" screen | Update EEPROM, BOOT_ORDER=0xf14 |
| SSD visible but no boot | Blue USB 3.0 port, 3A power adapter |
| No boot after clone | Use geerlingguy/rpi-clone fork (not billw2) |
| Bad USB cable | "J Micro" chipset problematic; try another cable |
| Slow | May be on USB 2.0 port |

## References

- https://www.raspberrypi.com/documentation/computers/raspberry-pi.html#usb-mass-storage-boot
- https://rpi-clone.jeffgeerling.com/ (for cloning)
- https://raspberry.tips/en/raspberrypi-tutorials/boot-raspberry-pi-from-usb-ssd-flash-drive-pi-4-5
