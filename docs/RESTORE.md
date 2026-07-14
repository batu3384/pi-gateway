# Geri Yükleme (Restic)

## Ön koşul

- `RESTIC_PASSWORD` (`.env` veya güvenli kasada)
- Yerel repo: `/mnt/ssd/pi-gateway-data/backups/restic`
- Mac kopyası: `make backup-pull` → `~/Backups/pi-gateway/restic`

## Snapshot listesi

```bash
ssh batu@PI_IP 'source ~/pi-gateway/.env && docker run --rm \
  -e RESTIC_PASSWORD -v /mnt/ssd/pi-gateway-data/backups/restic:/repo \
  restic/restic -r file:///repo snapshots'
```

## Tek dosya / klasör geri yükleme

```bash
# Örnek: config/adguard template
docker run --rm -e RESTIC_PASSWORD \
  -v /mnt/ssd/pi-gateway-data/backups/restic:/repo \
  -v /tmp/restore:/restore \
  restic/restic -r file:///repo restore latest \
  --target /restore --include /backup/config
```

## Tam felaket senaryosu

1. Pi’yi yeniden kur (`make install` veya SSD imajı)
2. `.env` dosyasını güvenli kaynaktan geri koy
3. `make deploy`
4. Restic’ten veri dizinini geri yükle:

```bash
docker run --rm -e RESTIC_PASSWORD \
  -v /mnt/ssd/pi-gateway-data/backups/restic:/repo \
  -v /mnt/ssd/pi-gateway-data:/data \
  restic/restic -r file:///repo restore latest --target /data
```

5. `docker compose up -d` + `configure-adguard.sh`
6. `smoke-test.sh` (15/15 beklenir)

## Aylık drill

Ayda bir `make backup-pull` + Mac’te `restic check` çalıştırın.
