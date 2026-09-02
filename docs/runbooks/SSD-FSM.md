# SSD Storage FSM — Operator Runbook

Tek sayfa: **degraded** veya SSD sorununda ne yapılır.

## Hızlı teşhis

```bash
# Pi üzerinde
cat /var/lib/pi-gateway/state.json
cat /run/pi-gateway/storage-degraded 2>/dev/null && echo DEGRADED || echo OK
mountpoint /mnt/ssd && df -h /mnt/ssd
docker info --format '{{.DockerRootDir}}'
```

| Belirti | Muhtemel durum |
|---------|----------------|
| `storage_degraded: 1` | SSD yok/stale — core-dns modu |
| `ssd_mount_healthy: 0` | Mount yok veya yazma testi fail |
| `docker_root_on_ssd: 0` | Docker hâlâ SD veya SSD restore eksik |
| `containerd_on_ssd: 1` | Deneysel — JMicron overlay segfault riski; default 0 (SD) |
| DNS çalışıyor, paneller yok | Beklenen degraded modu |

## Degraded modu (otomatik)

SSD kaybında stack **unbound + adguard + homepage + caddy** ile devam eder. App verisi SD'ye yazılmaz.

**Yapma:**
- `docker compose up` full stack (SD clobber riski)
- SSD takılı değilken n8n başlatma

**Yap:**
1. SSD kablo/güç kontrol
2. `mountpoint /mnt/ssd` — yoksa fiziksel düzelt
3. Otomatik: `ssd-hotplug-handler` veya `recover-readonly-root.sh`
4. Manuel: `REMOTE_DIR=~/pi-gateway bash ~/pi-gateway/scripts/pi/recover-readonly-root.sh`

## SSD geri geldi ama degraded kaldı

```bash
# SSD sağlıklı + Docker SSD root OK olmalı
bash ~/pi-gateway/scripts/pi/recover-readonly-root.sh
```

`clear_storage_degraded` yalnızca `ssd_mount_healthy` **ve** `docker_ssd_root_ok` ile çalışır.

## Komutlar (Mac)

| Komut | Açıklama |
|-------|----------|
| `make status` | Pi özeti |
| `make test-remote` | health + smoke |
| `make recover-stack` | Uzaktan recover tetikle |
| `make chaos-drill` | FSM dry-run (Pi) |

## Canlı chaos tatbikatı (nadir)

```bash
ssh pi 'CHAOS_DRY_RUN=false CHAOS_CONFIRM=yes REMOTE_DIR=~/pi-gateway bash ~/pi-gateway/scripts/pi/chaos-storage-drill.sh'
```

SSD sağlıklıyken degraded flag simüle eder → core-dns → DNS test → full recover.

## İlgili dosyalar

- `scripts/lib/stack-health.sh` — FSM bayrakları
- `scripts/pi/recover-readonly-root.sh` — ana kurtarma
- `scripts/pi/ssd-hotplug-handler.sh` — hotplug
- `scripts/pi/recover-compose-up.sh` — compose modları
