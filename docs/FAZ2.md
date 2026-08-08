# Phase 2 — Git, Sync, Backup

> **TLS varsayılan.** Panel URL'leri `https://*.home` — bkz. [OPERATIONS.md](OPERATIONS.md).  
> Ham IP/port referansları yalnızca TLS kapalı veya ilk kurulum için.

## Services

| Service | URL | Role |
|---------|-----|------|
| Forgejo | https://git.home | Git server |
| Syncthing | https://sync.home | Mac ↔ Pi file sync |
| Restic | (background) | Daily backup on SSD |

`PI_STATIC_IP` = LAN IP in `.env` (SSH / doğrudan port erişimi).

## Forgejo first-time setup

1. Browser: https://git.home
2. Create admin user on first launch
3. Add remote from Mac:
   ```bash
   git remote add pi https://git.home/user/repo.git
   git push pi main
   ```

## Syncthing — Mac ↔ Pi

### Pi side
- Folder: `/var/syncthing/Projects` (SSD: `/mnt/ssd/pi-gateway-data/projects`)
- UI: https://sync.home

### Mac side
1. Install [Syncthing](https://syncthing.net/downloads/) or `brew install syncthing`
2. Mac Syncthing UI: http://127.0.0.1:8384
3. **Add Remote Device** → enter Pi device ID (Pi UI → top right)
4. Approve Mac on the Pi
5. On Mac, share: `~/Projects` (Send Only or Send & Receive)
6. On Pi, map folder: `Projects` → `/var/syncthing/Projects`

### Device ID (Pi)
```bash
ssh "$PI_USER@$PI_STATIC_IP" 'docker exec syncthing cat /var/syncthing/config/config.xml | grep -oP "(?<=<device id=\")[^\"]+" | head -1'
```

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
