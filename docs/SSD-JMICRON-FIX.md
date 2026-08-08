# SSD Boot — Professional Diagnosis and Fix

Updated: 2026-07-11

## Facts (forums + official docs)

1. **SSD / image can be fine on Mac**; Pi USB **bootloader** stage is separate.
2. `usb-storage.quirks` is a **Linux kernel** setting. On the rainbow screen (no kernel) it **does nothing**.
3. YongzhenWeiye = JMicron **JMS583** (`152d:0583`) — known Pi 4 incompatibility ([rpi-eeprom#266](https://github.com/raspberrypi/rpi-eeprom/issues/266)).
4. Bootloader fixes live in **EEPROM**: `USB_MSD_PWR_OFF_TIME=0`, `USB_MSD_DISCOVER_TIMEOUT`, `USB_MSD_STARTUP_DELAY`.

## Done on Mac (`harden-ssd-boot.sh`)

- quirks + rootdelay=25
- quiet/splash removed (boot log visible)
- boot_delay=5, hdmi_force_hotplug, usb_max_current
- ssh + cloud-init check

## Required on Pi — with SD (manual or script)

**Architecture A (SD boot + SSD root):** `BOOT_ORDER=0xf41` (SD first)  
**Architecture B (full USB boot, SD removed):** `BOOT_ORDER=0xf14` (USB first)

Automatic (A):
```bash
CONFIRM_EEPROM_FIX=yes sudo bash ~/pi-gateway/scripts/pi/fix-eeprom-usb-ssd.sh
sudo reboot
```

Manual:
```bash
sudo -E rpi-eeprom-config --edit
```

For architecture A, add / update:

```
BOOT_ORDER=0xf41
USB_MSD_PWR_OFF_TIME=0
USB_MSD_DISCOVER_TIMEOUT=25000
USB_MSD_STARTUP_DELAY=5000
```

Save, `sudo reboot`. Then verify:

```bash
sudo rpi-eeprom-config | grep -E 'BOOT_ORDER|USB_MSD'
```

## Test sequence

1. SD booted → attach SSD → `lsusb` / `lsblk` (disk should appear in Linux)
2. EEPROM script → reboot → verify
3. Remove SD → SSD on USB **2.0** → power on
4. If that fails: ASMedia enclosure or `make install` from SD

## Permanent fix

USB-SATA adapter with ASMedia chipset. 24/7 USB boot with JMicron is not recommended.

## Runtime auto-recovery (hybrid data disk — no new hardware)

Kernel quirk alone is not enough when the bridge flaps after boot. Pi Gateway software path:

1. **Detect** — `ssd_mount_healthy()`: `mountpoint` + timed write to `/mnt/ssd/.disk-probe` (stale/hung mount).
2. **Soft-reset** — `ssd_usb_soft_reset()`: disable autosuspend, remount; optional `SSD_USB_AUTHORIZED_RESET=true` for `authorized` 0→1 (default **off** — JMS583 often disappears after authorize cycle). Rate-limited (`SSD_USB_RESET_MAX` / `SSD_USB_RESET_WINDOW_SEC`). **No xhci rebind.**
3. **Degraded** — if still dead: `/run/pi-gateway/storage-degraded`, stop app containers, `COMPOSE_RECOVER_MODE=core-dns`.
4. **Restore** — hotplug `PathExistsGone`/`PathChanged` + `ssd-health` poll: remount first → clear flag → full stack.

udev: `host/udev/99-pi-gateway-jmicron.rules` (`power/control=on`).

**Ceiling:** if `lsusb` never shows the device (bus dead), soft-reset may fail — optional `SSD_USB_RESET_REBOOT=true` (default off). Hardware upgrade still wins for 24/7 root-on-USB.
