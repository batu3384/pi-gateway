# ADR-001: Hybrid SD root + SSD data

## Status

Accepted (production default)

## Context

Pi 4B USB SSD (often JMicron) is unreliable as root. SD wears under Docker write load. Need durable boot and durable app data.

## Decision

- `STORAGE_TYPE=hybrid`: OS on SD (`/`), app data on `/mnt/ssd/pi-gateway-data` via `~/pi-gateway/data` symlink.
- Docker images stay on SD (`ENABLE_DOCKER_SSD=false` default).
- On SSD loss: `DNS_DEGRADED_ON_SSD_LOSS=true` keeps Unbound+AdGuard on SD; panels may stop.
- `ssd-root` is **experimental** — see `docs/SSD-ROOT.md`, scripts under Mac migrate/cutover.
- **Runtime recovery (software):** `ssd_mount_healthy` (write probe) detects stale mounts; `ssd_usb_soft_reset` cycles JMicron USB `authorized` / xhci rebind; `PathExistsGone` hotplug + `ssd-health` poll enter/leave degraded without requiring reboot when the bus still responds.

## Consequences

- Boot reliability high; data capacity on SSD.
- SSD unplug degrades to DNS-only (by design).
- Operators must not treat SSD restic alone as offsite backup (ADR-004).
- Soft-reset cannot fix total electrical dropout; ASMedia enclosure / better PSU remain the hardware upgrade path.
