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
| `pi-open` | `https://gateway.home` tarayıcıda aç (TLS kapalıysa `http://`) |
| `pi-logs` | `https://logs.home` |
| `pi-status` | `https://status.home` |
| `make telegram-menu` | Telegram panel menüsü |

Kurulum: `make pi-access`

## Paneller (`*.home`)

`ENABLE_TLS=true` iken tüm paneller **HTTPS** (`https://*.home`). TLS kapalıysa `http://`.

### Çift giriş (normal)

1. **Caddy basic auth** — tüm `*.home` panelleri (varsayılan: `AGH_ADMIN_USER` + `AGH_ADMIN_PASSWORD`; `CADDY_AUTH_*` set ise onlar)
2. **Uygulama girişi** — servisin kendi kullanıcı/şifresi (Homepage hariç)

| URL | Servis | Caddy | Uygulama |
|-----|--------|-------|----------|
| https://gateway.home | Homepage (ana panel) | `AGH_ADMIN_*` | — |
| https://panel.home | Homepage (alias) | aynı | — |
| https://status.home | Uptime Kuma | aynı | `UPTIME_KUMA_ADMIN_*` |
| https://logs.home | Dozzle | aynı | `DOZZLE_ADMIN_*` |
| https://dns.home | AdGuard | aynı | `AGH_ADMIN_*` |
| https://git.home | Forgejo | aynı | `FORGEJO_ADMIN_*` |
| https://sync.home | Syncthing | aynı | `SYNCTHING_GUI_*` |
| https://n8n.home | n8n | aynı | Owner (ilk kurulumda web UI) |

Public durum sayfası: `https://status.home/status/pi-gateway` (Caddy auth sonrası).

Mac'te HTTPS sertifika uyarısı: `make trust-ca`.

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

| Kaynak | Ne gönderir |
|--------|-------------|
| `health-check` timer | DNS hatası, disk %80+, SD uyarıları |
| `restic-backup` | Yedek tamamlandı |
| `stack-watchdog` / SSD hotplug | Stack veya SSD kurtarma |
| `morning-summary.sh` (08:00 timer) | Günlük sabah özeti |
| n8n ← Uptime Kuma webhook | Servis düştü / tekrar ayakta |
| n8n ← Forgejo push webhook | Git push (repo: `FORGEJO_REPO_NAME`) |

| Komut | Açıklama |
|-------|----------|
| `make telegram-test` | Test mesajı |
| `make telegram-menu` | Panel link butonları |
| `make morning-test` | Sabah özeti hemen gönder |

Bot yalnızca bildirim gönderir; gelen mesajlara cevap vermez.

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
