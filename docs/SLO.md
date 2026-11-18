# Service Level Objectives — Pi Gateway

Operational targets for Path A (Güven). Verified by `health-check`, `export-gateway-state`, and Gatus external-endpoint PUSH monitors.

## SLO table

| SLO | Target | Signal | Alert |
|-----|--------|--------|-------|
| **DNS availability** | 99.9% / 30d | `stack_dns_core_ok`, dig tests | health-check, Gatus DNS/Unbound |
| **Storage healthy** | degraded < 0.1% uptime | `storage_degraded` flag, `ssd_mount_healthy` | PUSH `slo_storage-healthy` |
| **Offsite backup** | age ≤ 7 days | `/var/lib/pi-gateway/last-offsite-backup` | Telegram yedek SLA (health exit 0), PUSH offsite |
| **Local config backup** | age ≤ 26 h | `~/pi-gateway/backups/20*` + `pi-gateway-backup.service` | health `local-backup-*` SLO |
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

## Gatus PUSH monitors

Rendered via `config/gatus/config.yaml.template` (`render-config.sh`). Tokens are derived deterministically from `.env` (`chmod 600` on rendered `config/gatus/config.yaml`, gitignored).

Heartbeats: `push-slo-heartbeat.sh` (health timer, every 2 min). Gatus does not send duplicate Telegram alerts; `notify.sh` is the sole notification channel.

## Related

- [ADR-004](adr/004-backup-3321.md) — 3-2-1 backup
- [OPERATIONS.md](OPERATIONS.md) — SSD degraded runbook
- [RESTORE.md](RESTORE.md) — disaster recovery
