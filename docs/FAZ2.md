# Phase 2 — Backup

> **Forgejo / Syncthing removed** from the stack. Phase 2 is Restic-only.
>
> **TLS varsayılan.** Panel URL'leri `https://*.home` — bkz. [OPERATIONS.md](OPERATIONS.md).

## Services

| Service | URL | Role |
|---------|-----|------|
| Restic | (background) | Daily backup on SSD |

`PI_STATIC_IP` = LAN IP in `.env` (SSH / doğrudan port erişimi).

## Restic backup

`.env`:
```
ENABLE_RESTIC=true
RESTIC_PASSWORD=StrongPasswordHere
RESTIC_REPOSITORY=/mnt/ssd/pi-gateway-data/backups/restic
```

Manual run:
```bash
ssh "$PI_USER@$PI_STATIC_IP" 'REMOTE_DIR=~/pi-gateway bash ~/pi-gateway/scripts/pi/restic-backup.sh'
```

Automatic: `pi-gateway-backup.timer` (daily).

**3-2-1 doğrulama (Mac):**
```bash
make backup-pull
make restore-check
```

Snapshot list:
```bash
ssh "$PI_USER@$PI_STATIC_IP" 'docker run --rm -e RESTIC_PASSWORD=... -v /mnt/ssd/pi-gateway-data/backups/restic:/repo restic/restic:0.17.3 -r file:///repo snapshots'
```
