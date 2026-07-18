# Operasyon Rehberi

Pi Gateway homelab — günlük kullanım, deploy ve sorun giderme.

## Depolama (hybrid — varsayılan)

Üretim: **SD = boot + root**, **SSD = veri** (`/mnt/ssd`). Ayrıntı: `docs/SSD-KURULUM.md`.

```bash
findmnt -n -o SOURCE /          # mmcblk0p2 (SD root)
findmnt -n -o SOURCE /mnt/ssd    # /dev/sda1
readlink -f ~/pi-gateway/data    # /mnt/ssd/pi-gateway-data
docker info | grep "Docker Root Dir"   # /var/lib/docker (varsayılan)
```

SSD imaj / hybrid boot: `scripts/mac/restore-hybrid-boot.sh`  
Deneysel ssd-root: `docs/SSD-ROOT.md`

## Hızlı erişim (Mac)

| Komut | Açıklama |
|-------|----------|
| `ssh pi` | Pi'ye LAN üzerinden SSH |
| `ssh pi-ts` | Pi'ye Tailscale üzerinden SSH |
| `pi-open` | `http://gateway.home` tarayıcıda aç |
| `pi-logs` | `http://logs.home` |
| `pi-status` | `http://status.home` |
| `make telegram-menu` | Telegram panel menüsü |

Kurulum: `make pi-access`

## Paneller (`*.home`)

| URL | Servis |
|-----|--------|
| http://gateway.home | Homepage (ana panel) |
| http://status.home | Uptime Kuma |
| http://logs.home | Dozzle (container logları) |
| http://dns.home | AdGuard |
| http://git.home | Forgejo |
| http://sync.home | Syncthing |
| http://n8n.home | n8n otomasyon |

Uzaktan erişim: Tailscale açık + MagicDNS (`home` split DNS). Ayrıntı: `docs/TAILSCALE.md` (ACL: `config/tailscale/acl.hujson.example`).

## Günlük komutlar (Mac)

| Komut | Açıklama |
|-------|----------|
| `make status` | Pi uptime, docker, health |
| `make dns-test` | DNS engel + rewrite testi |
| `make test-remote` | health + smoke (16+ kontrol) |
| `make verify-data` | Hybrid SSD symlink doğrulama |
| `make backup-pull` | Restic + config offsite kopya |
| `make backup-cron` | Haftalık backup-pull (Pazar 03:00) |

## Deploy

```bash
make render && make validate && make deploy
# veya hizli (pull yok):
make deploy-fast
```

Sıra: ön kontrol → rsync (data hariç) → bootstrap → docker compose → post-deploy → smoke test.

Deploy başarısız olursa: `make verify-data` ile `data/` symlink kontrol et; `data/` asla rsync ile silinmemeli.

## Güvenlik (varsayılan)

- **UFW:** `caddy-only` — admin panelleri yalnızca `*.home` (port 80/443) üzerinden
- **Şifreler:** servis başına ayrı (`.env`, git'e girmez)
- **Tailscale:** UFW'de yalnızca 22/80/443; ACL ile cihaz kısıtı önerilir

Firewall yeniden uygula (Pi):

```bash
ssh pi 'REMOTE_DIR=~/pi-gateway bash ~/pi-gateway/scripts/pi/setup-firewall.sh'
```

## Pi reboot sonrası

1. 2–3 dk bekleyin (AdGuard filtre yüklemesi)
2. `make dns-test` veya `dig google.com @192.168.1.112`
3. `pi-gateway-recover-ro.service` root ve stack kurtarmayı dener

## DNS çalışmıyor

1. `docker ps` → `adguard`, `unbound` healthy mi?
2. `journalctl -t pi-gateway-health -n 20`
3. `bash ~/pi-gateway/scripts/pi/configure-adguard.sh`
4. Mac DNS: Pi IP; router'da birincil DNS Pi olmalı

## Disk dolu

Hybrid modda: **SD** OS + Docker imajları; **SSD** uygulama verisi.

```bash
df -h / /mnt/ssd
docker info | grep "Docker Root Dir"
```

`docker system prune` (dikkatli). Restic `forget --prune` gunluk calisir.

## Bildirimler

`.env`: `TELEGRAM_BOT_TOKEN` + `TELEGRAM_CHAT_ID`

- DNS health fail
- Disk %80+
- Restic yedek başarılı
- n8n sabah özeti (08:00, workflow kuruluysa)
- **Sabah özeti (08:00):** systemd timer + Telegram (`make morning-test`)

Test: `make telegram-test`

## Şifreler

Tüm şifreler Mac'teki `.env` dosyasında. Servisler:

| Değişken | Servis |
|----------|--------|
| `AGH_ADMIN_PASSWORD` | AdGuard |
| `DOZZLE_ADMIN_PASSWORD` | Dozzle |
| `UPTIME_KUMA_ADMIN_PASSWORD` | Uptime Kuma |
| `SYNCTHING_GUI_PASSWORD` | Syncthing |
| `FORGEJO_ADMIN_PASSWORD` | Forgejo |
| `RESTIC_PASSWORD` | Yedekleme |

Yeni şifre üret: `openssl rand -base64 18 | tr -d '/+=' | head -c 20`

Deploy sonrası post-deploy scriptleri şifreleri uygular.

## Yedekleme (3-2-1)

1. **Pi SSD:** Restic günlük (`pi-gateway-backup.timer`)
2. **Mac offsite:** `make backup-pull` veya `make backup-cron`
3. Hedef: `~/Backups/pi-gateway/`

## İlgili dokümanlar

- `docs/ENV.md` — tüm ortam değişkenleri
- `docs/SECURITY.md` — güvenlik modeli
- `docs/RESTORE.md` — felaket kurtarma
- `config/tailscale/acl.hujson.example` — Tailscale ACL şablonu
