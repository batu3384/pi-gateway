# SD Boot + SSD Rootfs (Architecture A)

Production target: **SD boot only**, **SSD = rootfs + Docker + data**.

## Architecture

```
Pi EEPROM → SD bootfs (firmware/kernel/cmdline)
         → cmdline root=PARTUUID=<ssd> → SSD ext4 /
```

| Disk | Role |
|------|------|
| SD `bootfs` | firmware, kernel, cmdline, config |
| SSD root | OS, apt, home, Docker, pi-gateway data |

`STORAGE_TYPE=ssd-root` — hybrid (`/mnt/ssd` data disk) is **not** the production default; treated as experimental due to JMicron USB and EEPROM risk.

## Cutover (Mac)

**Prerequisite:** Restic / `make backup-pull` (or conscious risk acceptance). Pi powered off. SD + SSD on Mac USB.

```bash
cd ~/Documents/raspberrypi
# SSD is wiped — confirmation required
PI_PASSWORD='...' CONFIRM=yes ./scripts/mac/migrate-sd-boot-ssd-root.sh

# Mandatory verification (no false green):
PI_SD_DISK=/dev/diskXX PI_SSD_DISK=/dev/diskYY ./scripts/mac/verify-ssd-root.sh
```

`verify-ssd-root` matches SD and SSD bootfs **by disk identity**; SD `root=` and SSD `root=` must match and differ from the old SD PARTUUID. SD must have `resize` + `user-data`/`ssh` (firmware boots from SD).

Post-cutover repair (Mac, disks attached):
```bash
PI_SD_DISK=/dev/diskXX PI_SSD_DISK=/dev/diskYY ./scripts/mac/repair-cutover-bootfs.sh
```
SD is golden source; firmware/kernel/initramfs copied from SD bootfs to SSD via snapshot. If SSD bootfs corrupts on JMicron reader, `STRICT_SSD_BOOTFS=no` (default) warns — in architecture A the Pi boots from SD bootfs.

1. Insert SD + SSD into Pi (SSD → blue USB 3.0)
2. Power on, wait ~3–5 min (resize + cloud-init)
3. SSH: `findmnt -n -o SOURCE /` → **must not be mmcblk**
4. `.env`: `STORAGE_TYPE=ssd-root`
5. Mac: `./scripts/mac/deploy.sh`
6. On first login: strong password (`passwd`) + `ssh-copy-id` + disable PasswordAuthentication
7. After deploy (automatic): `ssd-root-harden.sh` (EEPROM + root check)
8. Legacy SD root:
   `CONFIRM=yes sudo bash ~/pi-gateway/scripts/pi/neutralize-legacy-sd-root.sh`
   or `CONFIRM_NEUTRALIZE=yes` during deploy

### EEPROM (if needed, once with old SD root)

```bash
sudo rpi-eeprom-config --edit
# BOOT_ORDER=0xf41   # SD first, then USB
# USB_MSD_PWR_OFF_TIME=0
# USB_MSD_DISCOVER_TIMEOUT=25000
# USB_MSD_STARTUP_DELAY=5000
```

JMicron adapter: `docs/SSD-JMICRON-FIX.md`.

## Verification

```bash
findmnt -n -o SOURCE,FSTYPE /
# /dev/sdX2  ext4

df -h /
REMOTE_DIR=~/pi-gateway bash ~/pi-gateway/scripts/pi/smoke-test.sh
# root-on-ssd PASS

REMOTE_DIR=~/pi-gateway bash ~/pi-gateway/scripts/pi/reboot-smoke.sh post
```

## Difference from hybrid

| | hybrid (legacy) | ssd-root |
|--|-----------------|----------|
| OS | SD | SSD |
| Root RO risk | High (SD I/O) | Low |
| `/mnt/ssd` | Required data disk | N/A |
| `data/` | symlink | native directory |
| Docker root | `/mnt/ssd/docker` | `/var/lib/docker` (on SSD) |

## Alternative B

Full USB SSD boot (SD removed): `docs/SSD-INSTALL.md` — not this project's default.
