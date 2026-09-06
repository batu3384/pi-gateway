# Restore (Restic)

## Prerequisites

- `RESTIC_PASSWORD` (`.env` or secure vault)
- Local repo: `/mnt/ssd/pi-gateway-data/backups/restic` (symlink: `~/pi-gateway/data/backups/restic`)
- Mac copy: `make backup-pull` → `~/Backups/pi-gateway/restic`
- Restic image pin: `RESTIC_IMAGE` in scripts (default **0.19.1** digest). Pi backup and Mac `backup-pull` check use the same image when Docker is available.

## Snapshot list

```bash
ssh "$PI_USER@$PI_STATIC_IP" 'source ~/pi-gateway/.env && docker run --rm \
  -e RESTIC_PASSWORD \
  -v /mnt/ssd/pi-gateway-data/backups/restic:/repo \
  restic/restic@sha256:136600b6ff6843d61d355f7f71f460a166429f35de6fd11b568fece3c9a4d510 \
  -r file:///repo snapshots'
```

## Single file / folder restore

```bash
# Example: config/adguard template
docker run --rm -e RESTIC_PASSWORD \
  -v /mnt/ssd/pi-gateway-data/backups/restic:/repo \
  -v /tmp/restore:/restore \
  restic/restic@sha256:136600b6ff6843d61d355f7f71f460a166429f35de6fd11b568fece3c9a4d510 \
  -r file:///repo restore latest \
  --target /restore --include /backup/config
```

Runtime `AdGuardHome.yaml` is not in config snapshots or Mac pull — restore via `make render` + `apply-adguard-dns` / `apply-adguard-filters` on Pi.

## Full disaster scenario

1. Reinstall Pi (`make install` or SSD image)
2. Restore `.env` from secure source
3. `make deploy`
4. Restore data directory from Restic:

```bash
docker run --rm -e RESTIC_PASSWORD \
  -v /mnt/ssd/pi-gateway-data/backups/restic:/repo \
  -v /mnt/ssd/pi-gateway-data:/data \
  restic/restic@sha256:136600b6ff6843d61d355f7f71f460a166429f35de6fd11b568fece3c9a4d510 \
  -r file:///repo restore latest --target /data
```

5. `docker compose up -d` + `configure-adguard.sh`
6. `scripts/pi/smoke-test.sh` (all checks green)
7. Optional: `scripts/pi/reboot-smoke.sh post` (post-reboot `recover-ro` + smoke)

Restic backup is skipped when SSD is missing or in degraded mode (`restic-backup.sh`).

## Corrupt repo recovery

1. `REMOTE_DIR=~/pi-gateway bash ~/pi-gateway/scripts/pi/restic-repair.sh` (unlock → repair index/snapshots/packs → `check`)
2. If `check` still fails: move repo to `/mnt/ssd/pi-gateway-recovery/restic.corrupt.<stamp>/`, create empty repo dir, run `restic-backup.sh` (or `RESTIC_ALLOW_REINIT=true` via `restic-backup.sh` auto path)
3. `make backup-pull` on Mac — remote snapshot count may be lower than local offsite; pull proceeds when remote `restic check` passes

## Monthly drill

```bash
make backup-pull
make restore-check
```

`restore-check` runs read-only `restic check --no-lock --read-data-subset=5%` on Pi SSD repo and Mac offsite copy (`RESTIC_CHECK_SUBSET` override in `.env`). Mac `backup-pull` prefers Docker + pinned `RESTIC_IMAGE` for `check` (native macOS restic may differ). Read-only check corruption bildirirse `repair packs`, `repair snapshots --forget` veya reinit otomatik çalıştırılmaz; önce repository kopyası alınır. Kurtarılamayan repo için temiz repo yeni snapshot ile oluşturulur, eski repo `/mnt/ssd/pi-gateway-recovery/` altında korunur ve ardından `make backup-pull` ile offsite yenilenir. `backup-restore-drill` başarısızsa Pi'ye `/var/lib/pi-gateway/last-backup-restore-drill-failure` marker'ı yazar ve dashboard'da `pi_gateway_backup_restore_drill_failed=1` görünür.
