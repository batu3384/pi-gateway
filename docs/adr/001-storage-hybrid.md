# ADR-001: Hybrid SD root + SSD data

## Status

Accepted (production default)

## Context

Pi 4B USB SSD (often JMicron) is unreliable as root. SD wears under Docker write load. Need durable boot and durable app data.

## Decision

- `STORAGE_TYPE=hybrid`: OS on SD (`/`), app data on `/mnt/ssd/pi-gateway-data` via `~/pi-gateway/data` symlink.
- Docker images: default SD (`ENABLE_DOCKER_SSD=false`). Opt-in `ENABLE_DOCKER_SSD=true` moves `data-root` to `/mnt/ssd/docker`; on SSD loss `setup-docker-fallback.sh` reverts to `/var/lib/docker` (degraded). Restore paths (`ssd-hotplug`, `recover-readonly-root`) re-run `setup-docker-ssd.sh` when SSD is healthy again.
- On SSD loss: `DNS_DEGRADED_ON_SSD_LOSS=true` keeps Unbound+AdGuard on SD; panels may stop.
- `ssd-root` is **experimental** — see `docs/SSD-ROOT.md`, scripts under Mac migrate/cutover.
- **Runtime recovery (software):** `ssd_mount_healthy` (timed write + `fsync`) detects hung mounts. `ssd_usb_soft_reset` merdiven: LPM/autosuspend off → lazy umount → usb-storage unbind/bind → USB3 port tarama (ogrenilen port her zaman ilk; USB2 hub son care; `SSD_USB_PORT_SCAN_MAX=8`) → opt-in xHCI. Enumerate/mount basarisinda kota sifir. `pi-ssd-health.timer` `OnUnitInactiveSec=30s`. udev/hotplug `ssd_usb_learn_live_port`. Kota bir tarama turu = 1. `health-check` gozlem-only. Degraded = core-dns; restore = remount + symlink + full stack.

## Consequences

- Boot reliability high; data capacity on SSD.
- SSD unplug degrades to DNS-only (by design).
- Operators must not treat SSD restic alone as offsite backup (ADR-004).
- Soft-reset cannot fix total electrical dropout; ASMedia enclosure / better PSU remain the hardware upgrade path.
