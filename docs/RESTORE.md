# Restore (Restic)

## Prerequisites

- `RESTIC_PASSWORD` (`.env` or secure vault)
- Local repo: `/mnt/ssd/pi-gateway-data/backups/restic` (symlink: `~/pi-gateway/data/backups/restic`)
- Mac copy: `make backup-pull` → `~/Backups/pi-gateway/restic`

## Snapshot list

```bash
ssh "$PI_USER@$PI_STATIC_IP" 'source ~/pi-gateway/.env && docker run --rm \
  -e RESTIC_PASSWORD -v /mnt/ssd/pi-gateway-data/backups/restic:/repo \
  restic/restic -r file:///repo snapshots'
```

## Single file / folder restore

```bash
# Example: config/adguard template
docker run --rm -e RESTIC_PASSWORD \
  -v /mnt/ssd/pi-gateway-data/backups/restic:/repo \
  -v /tmp/restore:/restore \
  restic/restic -r file:///repo restore latest \
  --target /restore --include /backup/config
```

## Full disaster scenario

1. Reinstall Pi (`make install` or SSD image)
2. Restore `.env` from secure source
3. `make deploy`
4. Restore data directory from Restic:

```bash
docker run --rm -e RESTIC_PASSWORD \
  -v /mnt/ssd/pi-gateway-data/backups/restic:/repo \
  -v /mnt/ssd/pi-gateway-data:/data \
  restic/restic -r file:///repo restore latest --target /data
```

5. `docker compose up -d` + `configure-adguard.sh`
6. `scripts/pi/smoke-test.sh` (all checks green)
7. Optional: `scripts/pi/reboot-smoke.sh post` (post-reboot `recover-ro` + smoke)

Restic backup is skipped when SSD is missing or in degraded mode (`restic-backup.sh`).

## Monthly drill

```bash
make backup-pull
make restore-check
```

`restore-check` runs `restic check --read-data-subset=5%` on Pi SSD repo and Mac offsite copy (`RESTIC_CHECK_SUBSET` override in `.env`).
