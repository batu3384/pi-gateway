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

Remote access (telefon): Tailscale app **Connected** yeterli — butonlar `http://100.x/p/…` (MagicDNS / Use Tailscale DNS yok). Pi: `setup-caddy-lan-ip` TS:80→LAN Caddy DNAT. Menü sabitlenir. Details: `docs/TAILSCALE.md`.

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

## Deploy

```bash
make render && make validate && make deploy
# or fast (no pull):
make deploy-fast
```

Order: pre-check → rsync (excluding data) → bootstrap → docker compose → post-deploy → smoke test.

If deploy fails: run `make verify-data` to check `data/` symlink; `data/` must never be deleted by rsync.

## Security (defaults)

- **UFW:** `caddy-only` — admin panels only via `*.home` (ports 80/443)
- **Passwords:** per-service (`.env`, not in git)
- **Tailscale:** UFW allows only 22/80/443; device restriction via ACL recommended

Reapply firewall (Pi):

```bash
ssh pi 'REMOTE_DIR=~/pi-gateway bash ~/pi-gateway/scripts/pi/setup-firewall.sh'
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

`prune-sd-space.sh` (health ≥65%): apt/journal; docker prune only when data-root is on SD and not degraded.

`docker system prune` (careful). Restic `forget --prune` runs daily.

## Gateway state (observability)

Health timer writes:

- `/var/lib/pi-gateway/state.json` — human JSON (`make status`)
- `/var/lib/pi-gateway/metrics/pi_gateway.prom` — Prometheus textfile
- `/var/lib/pi-gateway/metrics/pi_gateway_adguard.prom` — AdGuard stats / per-list rules

SLO PUSH heartbeats → Uptime Kuma (`docs/SLO.md`).

## Backup confidence (3-2-1)

1. Pi SSD restic (encrypted) — daily timer (`post-deploy` tam yedek atlar; `POST_DEPLOY_RESTIC=true` zorla)
2. Mac `make backup-pull` — weekly cron recommended
3. Optional B2/R2 — `RESTIC_OFFSITE_ENABLED=true` (after local backup)
4. Monthly `make backup-restore-drill` — proves restore works

## Notifications

`.env`: `TELEGRAM_BOT_TOKEN` + `TELEGRAM_CHAT_ID`

| Source | What it sends |
|--------|---------------|
| `health-check` timer | DNS errors, disk 80%+, SD warnings |
| `restic-backup` | Backup completed |
| `health-check` / SSD hotplug | Stack or SSD recovery |
| n8n ← Uptime Kuma webhook | Service down / back up |
| Hermes cron (bülten) | Günaydın / piyasa / akşam / gece — ağ/saatlik gözcü kaldırıldı |
| Hermes cron (07:00 / 18:55 / 23:00) | Daily bulletins (morning / market / night) |

| Command | Description |
|---------|-------------|
| `make telegram-test` | Test message |
| `make telegram-menu` | Panel link buttons |

Bot sends notifications only; it does not reply to incoming messages.

### Hermes Agent (Telegram inbox)

When `HERMES_TELEGRAM_GATEWAY=true` in Pi `.env`:

- **Inbox:** `hermes-gateway.service` (Nous Hermes) owns `getUpdates` — chat + commands.
- **Outbox:** `notify.sh` keeps using the same `TELEGRAM_BOT_TOKEN` via `sendMessage`.
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
