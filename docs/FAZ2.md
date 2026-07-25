# Faz 2 — Git, Sync, Yedek

## Servisler

| Servis | URL | Rol |
|--------|-----|-----|
| Forgejo | http://git.home veya `http://PI_STATIC_IP:3002` | Git sunucusu |
| Syncthing | http://sync.home veya `http://PI_STATIC_IP:8384` | Mac ↔ Pi dosya senkronu |
| Restic | (arka plan) | Gunluk yedek, SSD uzerinde |

`PI_STATIC_IP` = `.env` icindeki LAN IP.

## Forgejo ilk kurulum

1. Tarayici: http://git.home veya `http://PI_STATIC_IP:3002`
2. Ilk acilista admin kullanici olustur
3. Mac'ten repo ekle:
   ```bash
   git remote add pi http://git.home/kullanici/repo.git
   git push pi main
   ```

## Syncthing — Mac ↔ Pi

### Pi tarafi
- Klasor: `/var/syncthing/Projects` (SSD: `/mnt/ssd/pi-gateway-data/projects`)
- UI: http://sync.home veya `http://PI_STATIC_IP:8384`

### Mac tarafi
1. [Syncthing](https://syncthing.net/downloads/) kur veya `brew install syncthing`
2. Mac Syncthing UI: http://127.0.0.1:8384
3. **Add Remote Device** → Pi cihaz ID'sini gir (Pi UI → ust sag kose)
4. Pi'de Mac'i onayla
5. Mac'te paylas: `~/Projects` (Send Only veya Send & Receive)
6. Pi'de klasor: `Projects` → `/var/syncthing/Projects` ile esle

### Cihaz ID (Pi)
```bash
ssh "$PI_USER@$PI_STATIC_IP" 'docker exec syncthing cat /var/syncthing/config/config.xml | grep -oP "(?<=<device id=\")[^\"]+" | head -1'
```

## Restic yedek

`.env`:
```
ENABLE_RESTIC=true
RESTIC_PASSWORD=GucluSifreBuraya
RESTIC_REPOSITORY=/mnt/ssd/pi-gateway-data/backups/restic
```

Manuel calistirma:
```bash
ssh "$PI_USER@$PI_STATIC_IP" 'REMOTE_DIR=~/pi-gateway bash ~/pi-gateway/scripts/pi/restic-backup.sh'
```

Otomatik: `pi-gateway-backup.timer` (gunluk).

Snapshot listesi:
```bash
ssh "$PI_USER@$PI_STATIC_IP" 'docker run --rm -e RESTIC_PASSWORD=... -v /mnt/ssd/pi-gateway-data/backups/restic:/repo restic/restic -r file:///repo snapshots'
```
