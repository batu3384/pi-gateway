# Operations Guide

Pi Gateway homelab — daily use, deploy, and troubleshooting.

## Storage (hybrid — default)

Production: **SD = boot + root**, **SSD = data** (`/mnt/ssd`). Details: `docs/SSD-INSTALL.md`.

```bash
findmnt -n -o SOURCE /          # mmcblk0p2 (SD root)
findmnt -n -o SOURCE /mnt/ssd    # /dev/sda1
readlink -f ~/pi-gateway/data    # /mnt/ssd/pi-gateway-data
docker info | grep "Docker Root Dir"   # /var/lib/docker (default) or /mnt/ssd/docker (ENABLE_DOCKER_SSD=true)
grep '^root' /etc/containerd/config.toml   # /var/lib/containerd (default); CONTAINERD_ON_SSD=true → /mnt/ssd/containerd
cat /var/lib/pi-gateway/state.json     # export-gateway-state (health timer)
cat /var/lib/pi-gateway/metrics/pi_gateway.prom   # Prometheus textfile
cat /var/lib/pi-gateway/metrics/pi_gateway_adguard.prom
```

SSD image / hybrid boot: `scripts/mac/restore-hybrid-boot.sh`  
Experimental ssd-root: `docs/SSD-ROOT.md`

### SSD dropped — what happens

1. **Detect** — udev (`SYSTEMD_WANTS=pi-ssd-watch.service`) + `PathChanged` on by-label, or health timer (`ssd-health` write-probe).
2. **Soft-reset** — JMicron USB authorize cycle / remount (rate-limited). See `docs/SSD-JMICRON-FIX.md`.
3. **Degraded** — flag `/run/pi-gateway/storage-degraded`; n8n/… stop; Unbound+AdGuard (core-dns) on SD.
4. **Restore** — disk healthy again → remount → symlink → full stack (no reboot required if bus responds).
5. **Deploy / restic** — while degraded: compose stays core-dns; restic **skips** (no ephemeral SSD-repo lie).

Manual trigger: `REMOTE_DIR=~/pi-gateway bash ~/pi-gateway/scripts/pi/ssd-health.sh`

### SSD SMART (wear)

Weekly timer `pi-gateway-ssd-smart.timer` (Sun 04:30) → `check-ssd-smart.sh`. Needs `smartmontools` (`setup-ssd-smart-timer.sh` installs). Journal: `journalctl -t pi-gateway-ssd-smart`. Wear ≥90% or realloc ≥10 → `notify_disk_warn`. JMicron USB: SMART via `-d sat` if `-d auto` empty; wear/realloc ATA kolon parse (USB köprü attribute vermezse `n/a` — health PASSED yine geçerli). Hardware flap (`152d:0583`) ≠ SMART wear — enclosure still ops decision (`docs/SSD-JMICRON-FIX.md`).

Manual: `REMOTE_DIR=~/pi-gateway bash ~/pi-gateway/scripts/pi/check-ssd-smart.sh`

## Quick access (Mac)

| Command | Description |
|---------|-------------|
| `ssh pi` | SSH to Pi over LAN |
| `ssh pi-ts` | SSH to Pi over Tailscale |
| `pi-open` | Open `https://gateway.home` in browser (`http://` if TLS off) |
| `pi-logs` | `https://logs.home` |
| `pi-status` | `https://status.home` |
| `make telegram-menu` | Telegram panel menu |

Setup: `make pi-access`

## Panels (`*.home`)

Visibility stack (Path B): `docs/VISIBILITY.md` — Grafana, Prometheus, Homepage widget.

With `ENABLE_TLS=true` (default), all panels use **HTTPS** (`https://*.home`). HTTP only with `WEAK_TLS_OK=yes`.

### Unified login (`UNIFIED_LOGIN=true`, default)

`AGH_ADMIN_USER` + `AGH_ADMIN_PASSWORD` = **tek sifre** Caddy ve servis GUI'leri icin. Deploy `sync-service-passwords` ile Dozzle, Uptime Kuma, NetAlertX ve Grafana sifrelerini esitler.

Caddy basic_auth her yerde `AGH_ADMIN_USER`.

| URL | Service | Caddy | App (unified) |
|-----|---------|-------|---------------|
| https://gateway.home | Homepage + gateway widget | `AGH_ADMIN_*` | — |
| https://panel.home | Homepage (alias) | same | — |
| https://status.home | Uptime Kuma | same | same |
| https://logs.home | Dozzle | same | same |
| https://dns.home | AdGuard | same | `AGH_ADMIN_*` |
| https://n8n.home | n8n | same | Owner (ilk kurulum; Caddy auth yeterli) |
| https://grafana.home | Grafana | same | `AGH_ADMIN_*` |
| https://devices.home | NetAlertX | — (API dongusu) | `AGH_ADMIN_*` |

Homepage **Gateway durumu** widget: `state.json` (SSD, yedek, drill metrikleri).

`UNIFIED_LOGIN=false` ise eski dual-login: her servis icin ayri `.env` sifresi.

Public status page: `https://status.home/status/pi-gateway` (after Caddy auth).

Mac HTTPS cert warning: `make trust-ca`.

Remote access (telefon): Tailscale **Connected** — paneller `http://100.x/p/…` (MagicDNS şart değil). **Filtre ev dışı:** Use Tailscale DNS + admin global NS=`100.x` + Override (`docs/TAILSCALE.md`). Private DNS / iCloud Relay / Chrome Secure DNS kapalı. Pi: `setup-caddy-lan-ip` TS:80→LAN Caddy DNAT.

## DNS rollout

1. ZTE LAN/DHCP DNS1’i Pi IP’ye ayarla; DNS2’yi boş bırak; lease’i yenile.
2. Mac’te `make mac-dns`, sonra `make dns-test` çalıştır.
3. Android’de Private DNS’i, iOS’ta Private Relay/Limit IP Tracking’i, tarayıcıda Secure DNS’i kapat.
4. TV/konsol manuel DNS kullanıyorsa Pi IP’sini yaz; public resolver veya modem `.1` ekleme.
5. Yayılımı `make rollout-dns-wait` ile bekle; sonucu `make audit-dns` ile doğrula.
6. `WARN`, `UNKNOWN` veya `POSSIBLE_BYPASS` cihazları reklam listesi sorunu sayma; cihaz DNS/IPv6 ayarını düzelt, sonra auditi tekrarla.

ZTE H3600P aynı Layer-2 ağda modem `.1:53` erişimini Pi’ye göndermez. Bu nedenle yalnız Pi DNS kullanan cihazlar kanıtlı korunur; tüm kablolu cihazları Pi’ye zorlamak mevcut ZTE + Pi donanımıyla mümkün değildir.

## Daily commands (Mac)

| Command | Description |
|---------|-------------|
| `make status` | Pi uptime, docker, health |
| `make dns-test` | DNS block + rewrite test |
| `make test-remote` | health + smoke (16+ checks) |
| `make verify-data` | Hybrid SSD symlink validation |
| USB SSD power | Direct USB3 + ≥3A PSU; if drops use powered **480M+** hub (not 12M Full-Speed) |
| `make backup-pull` | Restic + config offsite copy |
| `make backup-cron` | Weekly backup-pull (Sunday 03:00) |
| `make backup-restore-drill` | Restore latest offsite snapshot to temp + verify |
| `make config-drift` | Rendered config hash Mac vs Pi |
| `make restore-check` | `restic check` Pi + Mac offsite |

`make config-drift` generated bcrypt salt and trailing newline farklarını normalize eder; gerçek config değişikliği yine `DRIFT` olarak kalır.

## Deploy

```bash
# Full: bootstrap + compose canary + post-deploy + smoke (~dakikalar)
make deploy

# Code: rsync + privileged + Hermes/notify (günlük script/metin)
make deploy-code   # alias: make deploy-fast

# Full ama imaj pull yok
DEPLOY_SKIP_PULL=true make deploy

# Code + smoke
DEPLOY_SMOKE=true make deploy-code
```

| Mode | Ne yapar | Ne atlar |
|------|----------|----------|
| `full` (default) | validate → rsync → bootstrap → canary → post-deploy → smoke | — |
| `code` | validate → rsync → `post-deploy-code` | bootstrap, compose recreate, UFW/n8n/Kuma/CrowdSec |

Order (full): pre-check → rsync (excluding data) → bootstrap → docker compose → post-deploy → smoke test.

If deploy fails: run `make verify-data` to check `data/` symlink; `data/` must never be deleted by rsync.

## Security (defaults)

- **UFW:** `caddy-only` — admin panels only via `*.home` (ports 80/443)
- **Passwords:** per-service (`.env`, not in git). `.env` mode 600. Restic şifresi `.env` içinde (aynı disk; ciphertext tek başına açılmaz)
- **SSH:** key-only (`/etc/ssh/sshd_config.d/00-pi-gateway-ssh.conf`, sshd first-wins vs cloud-init). `pi` sudo parola ister; ilk bootstrap/post-deploy SSH PTY ile çalışır.
- **Prometheus:** Grafana scrape. Uyarı = health-check + Kuma + Telegram — Alertmanager yok
- **Tailscale:** UFW `tailscale0` `22/80/443` TCP + `:53` UDP+TCP (AdGuard). ACL `group:owners` / `tag:owner-device`. WAN `:53` kapalı.

SSH şifre geri (key kaybı): Pi HDMI/konsol veya SD `userconf`; sonra `sudo rm /etc/ssh/sshd_config.d/00-pi-gateway-ssh.conf && sudo systemctl reload ssh`

Reapply firewall (Pi):

```bash
ssh -tt pi 'REMOTE_DIR=~/pi-gateway bash ~/pi-gateway/scripts/pi/setup-firewall.sh'
```

## After Pi reboot

1. Wait 2–3 minutes (AdGuard filter loading)
2. `make dns-test` or `dig google.com @PI_STATIC_IP`
3. `pi-gateway-recover-ro.service` attempts root and stack recovery

## DNS not working

1. `docker ps` → are `adguard`, `unbound` healthy?
2. `journalctl -t pi-gateway-health -n 20`
3. `bash ~/pi-gateway/scripts/pi/configure-adguard.sh`
4. Mac DNS: Pi IP; router primary DNS should be Pi

## Disk full

In hybrid mode: **SD** = OS + containerd image store (Docker 29+); **SSD** = app data + Docker `data-root` when `ENABLE_DOCKER_SSD=true`. Do not set `CONTAINERD_ON_SSD=true` on JMicron USB — overlay segfault risk (homepage).

```bash
df -h / /mnt/ssd
docker info | grep "Docker Root Dir"
```

`prune-sd-space.sh` (health ≥65%): apt/journal; unused Docker image prune when **containerd is on SD** (Docker 29+ overlayfs snapshotter). Docker `data-root` on SSD does **not** skip this — layers still live in `/var/lib/containerd`. Skip image prune only if containerd root is already on `/mnt/ssd/*` or storage is degraded.

`docker system prune` (careful). Restic `forget --prune` runs daily.

## Gateway state (observability)

Health timer writes:

- `/var/lib/pi-gateway/state.json` — human JSON (`make status`)
- `/var/lib/pi-gateway/metrics/pi_gateway.prom` — Prometheus textfile
- `/var/lib/pi-gateway/metrics/pi_gateway_adguard.prom` — AdGuard stats / per-list rules / top clients+blocked
- `/var/lib/pi-gateway/metrics/pi_gateway_ibb.prom` — İBB HKI (en yakın istasyon, 30 dk)

SLO PUSH heartbeats → Uptime Kuma (`docs/SLO.md`).

## Backup confidence (3-2-1)

1. Pi SSD restic (encrypted) — daily timer (`post-deploy` tam yedek atlar; `POST_DEPLOY_RESTIC=true` zorla)
2. Mac `make backup-pull` — weekly cron recommended
3. Optional B2/R2 — `RESTIC_OFFSITE_ENABLED=true` (after local backup)
4. Monthly `make backup-restore-drill` — proves restore works

Başarısız restore drill `/var/lib/pi-gateway/last-backup-restore-drill-failure` marker’ı ve `pi_gateway_backup_restore_drill_failed=1` metric’i üretir; son başarılı drill yaşı tek başına güven kanıtı sayılmaz.

## Notifications

`.env`: `TELEGRAM_BOT_TOKEN` + `TELEGRAM_CHAT_ID`

| Source | What it sends |
|--------|---------------|
| `health-check` timer | DNS errors, disk/inode 80%+, düşük RAM, SD warnings |
| `restic-backup` | Backup completed |
| `health-check` / SSD hotplug | Stack or SSD recovery |
| n8n ← Uptime Kuma webhook | Service down / back up |
| `pi-gateway-quake.timer` (10s) | AFAD+Kandilli poll → outbox bot (Hermes yok; EEW değil) |
| `pi-gateway-ibb.timer` (30 dk) | İBB HKI ≥ `IBB_HKI_WARN` (51) → Telegram; iyileşince bir kez OK. API fail = sessiz |
| Hermes cron (bülten) | Günaydın / piyasa / akşam / gece — ağ/saatlik gözcü kaldırıldı |
| Hermes cron (07:00 / 18:55 / 23:00) | Daily bulletins (morning / market / night) |

**Deprem:** yayın sonrası bildirim. Gecikme ≈ kaynak sayfası + ≤10s poll. İlk koşu bootstrap (tarihî liste spam yok). Eşik/konum: `.env` `QUAKE_*` (bkz. `.env.example`).

**Hava (İBB):** en yakın sabit istasyon (varsayılan Aksaray civarı). HKI sarı bant (51+) geçiş bildirimi; tekrar `NOTIFY_IBB_REPEAT_SEC`. Ev bahçesi ölçümü değil — istasyon açık veri.

| Command | Description |
|---------|-------------|
| `make telegram-test` | Test message |
| `make telegram-menu` | Panel link buttons |

Bot sends notifications only; it does not reply to incoming messages.

### Hermes Agent (Telegram inbox)

When `HERMES_TELEGRAM_GATEWAY=true` in Pi `.env`:

- **Inbox:** `hermes-gateway.service` (Nous Hermes) owns `getUpdates` — chat + commands.
- **Outbox:** `notify.sh` keeps using the same `TELEGRAM_BOT_TOKEN` via `sendMessage`.
- **Identity:** deploy kopyalar `config/hermes/SOUL.md` → `~/.hermes/SOUL.md` + skill `pi-gateway-ops` (Forgejo/Syncthing yok). Ölü skill’ler (`imessage`, `findmy`, `comfyui`, `vllm`…) `skills.disabled`. Script: `setup-hermes-identity.sh`.
- **Panel menu:** `telegram-menu.sh` (Mac/outbox) or Hermes `/menu` skill → `hermes-menu.sh`.
- Secrets: `GLM_API_KEY` + Telegram token live in `~/.hermes/.env` (chmod 600). Coding Plan base URL: `https://api.z.ai/api/coding/paas/v4`. Default model: **`glm-5.3`** (`provider: zai` in `~/.hermes/config.yaml`).
- Browser (Pi aarch64): system Chromium (`apt install chromium`) + `agent-browser`; set `AGENT_BROWSER_EXECUTABLE_PATH=/usr/bin/chromium` (Chrome-for-Testing ARM64 yok).
- Allowlist: `TELEGRAM_ALLOWED_USERS` = numeric **user** id (not group chat id). Notify still uses `TELEGRAM_CHAT_ID`.

| Command | Description |
|---------|-------------|
| `sudo systemctl status hermes-gateway` | Gateway health |
| `hermes update && REMOTE_DIR=~/pi-gateway bash ~/pi-gateway/scripts/pi/patch-hermes-telegram-pi.sh && sudo systemctl restart hermes-gateway` | Update agent + re-apply Pi Telegram patch |
| `REMOTE_DIR=~/pi-gateway bash ~/pi-gateway/scripts/pi/setup-hermes-gateway.sh` | Reinstall unit + patch + drop-in |

**Pi Telegram patch:** `scripts/pi/patch-hermes-telegram-pi.sh` — cold-start `require_progress=False`, stepped `initialize`, `/etc/hosts` IPv4 pin for `api.telegram.org`, systemd drop-in (`HTTP_POOL_SIZE=8`). Needed because upstream `_await_with_thread_deadline` can wedge on long-poll here. Re-run after every `hermes update`.

**Disable Hermes inbox:** set `HERMES_TELEGRAM_GATEWAY=false` (or remove) in Pi `.env` → redeploy/`setup-hermes-gateway.sh` (`hermes-gateway` disabled; **no poller fallback** — inbox dark, outbox/`notify.sh` still works).

**Cutover fail:** if Connected check fails, unit stays **enabled** (`Restart=always`) and Telegram outbox alert fires (`_alert_inbox_down`). Fix: `journalctl -u hermes-gateway` → `setup-hermes-gateway.sh` again.

**Lifecycle Telegram:** Asistan kapanış → “kısa süre kapanıyor / yeniden başlatılıyor”. Asistan geri → “Sohbet asistanı yeniden aktif” (`hermes-inbox-up-notify.sh`). Pi reboot → “Açıldı” (`boot-notify.sh`). Crash-loop: `NOTIFY_HERMES_UP_COOLDOWN_SEC=120`.

**Token rotate:** update both `~/pi-gateway/.env` and `~/.hermes/.env`, then `systemctl restart hermes-gateway`.

**DM test:** Telegram’da `@RaspberryPi3384_bot` → allowlist user id ile mesaj. Outbox: `make telegram-test`.

| Command | Description |
|---------|-------------|
| `make telegram-test` | Test message |
| `make telegram-menu` | Panel link buttons (Mac/outbox; Hermes `/menu` skill on Pi when gateway active) |

Bot outbox: notifications. Hermes inbox: conversational replies when gateway is active.

## Passwords

1. **Pi SSD (encrypted data):** Restic via Docker (`pi-gateway-backup.timer` → `backup.sh` → `restic-backup.sh`). Runs as `PI_USER` with `REMOTE_DIR=~/pi-gateway` — never as root (`/home/root/...` is wrong).
2. **Config snapshot:** same timer writes `~/pi-gateway/backups/<stamp>/` (compose + config + env key names; no plaintext secrets).
3. **Mac offsite:** `make backup-pull` or `make backup-cron` → `~/Backups/pi-gateway/`
4. **Pi OS login kilit:** eski `reset-pi-password.sh` yok. Konsol/HDMI veya SD’yi Mac’te mount → `userconf` / raspi-config; SSH key `~/.ssh/authorized_keys` ile kurtar.

Verify: `systemctl cat pi-gateway-backup.service | grep -E 'User=|REMOTE_DIR'` and `ls ~/pi-gateway/backups`.

## USB SSD power (hybrid)

- Prefer **direct Pi USB3 (blue)** with a solid **5V ≥3A** PSU.
- If undervolt / disconnect: use a **powered USB 3.x or High-Speed (480 Mbps) hub** — not Full-Speed (12 Mbps) “USB 2.0” hubs.
- Check: `lsusb -t` (SSD line must show `480M` or `5000M`) and `vcgencmd get_throttled` (`0x0` ideal).

## Related docs

- `docs/ENV.md` — all environment variables
- `docs/SECURITY.md` — security model
- `docs/RESTORE.md` — disaster recovery
- `config/tailscale/acl.hujson.example` — Tailscale ACL template
