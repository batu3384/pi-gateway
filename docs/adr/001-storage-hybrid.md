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

## Consequences

- Boot reliability high; data capacity on SSD.
- SSD unplug degrades to DNS-only (by design).
- Operators must not treat SSD restic alone as offsite backup (ADR-004).
