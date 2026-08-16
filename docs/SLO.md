# Service Level Objectives — Pi Gateway

Operational targets for Path A (Güven). Verified by `health-check`, `export-gateway-state`, and Uptime Kuma PUSH monitors.

## SLO table

| SLO | Target | Signal | Alert |
|-----|--------|--------|-------|
| **DNS availability** | 99.9% / 30d | `stack_dns_core_ok`, dig tests | health-check, Uptime Kuma Unbound |
| **Storage healthy** | degraded < 0.1% uptime | `storage_degraded` flag, `ssd_mount_healthy` | PUSH `SLO Storage Healthy` |
| **Offsite backup** | age ≤ 7 days | `/var/lib/pi-gateway/last-offsite-backup` | Telegram yedek SLA (health exit 0), PUSH offsite |
| **Restore drill** | age ≤ 30 days | `last-backup-restore-drill` | health `backup-restore-drill-*`, PUSH drill |
| **SSD restore time** | < 120s (manual) | hotplug + recover journal | runbook `docs/OPERATIONS.md` |
| **Docker SSD consistency** | 100% when enabled | `docker_ssd_root_ok` | post-deploy-integration, smoke |

## Escape hatches

- `WEAK_BACKUP_OK=yes` — offsite/drill SLA health fail → warn only (doctor/health)
- `OFFSITE_BACKUP_MAX_AGE_DAYS=0` — disable offsite age check
- `BACKUP_DRILL_MAX_AGE_DAYS=0` — disable drill SLA

## Verification commands

```bash
# Mac
make backup-pull
make backup-restore-drill   # monthly
make restore-check
make config-drift

# Pi
cat /var/lib/pi-gateway/state.json
cat /var/lib/pi-gateway/metrics/pi_gateway.prom
systemctl list-timers pi-gateway-ssd-smart.timer
```

## Uptime Kuma PUSH monitors

Created by `setup-slo-monitors.sh` (post-deploy). Tokens: `data/uptime-kuma/slo-push-tokens.env` (mode 600, not in git).

Heartbeats: `push-slo-heartbeat.sh` (health timer, every 2 min).

## Related

- [ADR-004](adr/004-backup-3321.md) — 3-2-1 backup
- [OPERATIONS.md](OPERATIONS.md) — SSD degraded runbook
- [RESTORE.md](RESTORE.md) — disaster recovery
