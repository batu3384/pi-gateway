# Operations Guide

Pi Gateway homelab — daily use, deploy, and troubleshooting.

## Storage (hybrid — default)

Production: **SD = boot + root**, **SSD = data** (`/mnt/ssd`). Details: `docs/SSD-INSTALL.md`.

```bash
findmnt -n -o SOURCE /          # mmcblk0p2 (SD root)
findmnt -n -o SOURCE /mnt/ssd    # /dev/sda1
readlink -f ~/pi-gateway/data    # /mnt/ssd/pi-gateway-data
docker info | grep "Docker Root Dir"   # /var/lib/docker (default) or /mnt/ssd/docker (ENABLE_DOCKER_SSD=true)
cat /var/lib/pi-gateway/state.json     # export-gateway-state (health timer)
```

SSD image / hybrid boot: `scripts/mac/restore-hybrid-boot.sh`  
Experimental ssd-root: `docs/SSD-ROOT.md`

### SSD dropped — what happens

1. **Detect** — hotplug (`PathExistsGone` / `PathChanged`) or health timer (`ssd-health` write-probe).
2. **Soft-reset** — JMicron USB authorize cycle / remount (rate-limited). See `docs/SSD-JMICRON-FIX.md`.
3. **Degraded** — flag `/run/pi-gateway/storage-degraded`; Forgejo/n8n/… stop; Unbound+AdGuard (core-dns) on SD.
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

With `ENABLE_TLS=true` (default), all panels use **HTTPS** (`https://*.home`). HTTP only with `WEAK_TLS_OK=yes`.

### Dual login (normal)

1. **Caddy basic auth** — all `*.home` panels (default: `AGH_ADMIN_USER` + `AGH_ADMIN_PASSWORD`; `CADDY_AUTH_*` if set)
2. **App login** — each service's own user/password (except Homepage)

| URL | Service | Caddy | App |
|-----|---------|-------|-----|
| https://gateway.home | Homepage (main panel) | `AGH_ADMIN_*` | — |
| https://panel.home | Homepage (alias) | same | — |
| https://status.home | Uptime Kuma | same | `UPTIME_KUMA_ADMIN_*` |
| https://logs.home | Dozzle | same | `DOZZLE_ADMIN_*` |
| https://dns.home | AdGuard | same | `AGH_ADMIN_*` |
| https://git.home | Forgejo | same | `FORGEJO_ADMIN_*` |
| https://sync.home | Syncthing | same | `SYNCTHING_GUI_*` |
| https://n8n.home | n8n | same | Owner (web UI on first setup) |
| https://devices.home | NetAlertX (network inventory) | same | NetAlertX UI (password on first launch) |

Public status page: `https://status.home/status/pi-gateway` (after Caddy auth).

Mac HTTPS cert warning: `make trust-ca`.

Remote access: Tailscale enabled + MagicDNS (`home` split DNS). Details: `docs/TAILSCALE.md` (ACL: `config/tailscale/acl.hujson.example`).

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

In hybrid mode: **SD** = OS (+ Docker if `ENABLE_DOCKER_SSD=false`); **SSD** = app data (+ Docker if `ENABLE_DOCKER_SSD=true`).

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

SLO PUSH heartbeats → Uptime Kuma (`docs/SLO.md`).

## Backup confidence (3-2-1)

1. Pi SSD restic (encrypted) — daily timer
2. Mac `make backup-pull` — weekly cron recommended
3. Optional B2/R2 — `RESTIC_OFFSITE_ENABLED=true` (after local backup)
4. Monthly `make backup-restore-drill` — proves restore works

## Notifications

`.env`: `TELEGRAM_BOT_TOKEN` + `TELEGRAM_CHAT_ID`

| Source | What it sends |
|--------|---------------|
| `health-check` timer | DNS errors, disk 80%+, SD warnings |
| `restic-backup` | Backup completed |
| `stack-watchdog` / SSD hotplug | Stack or SSD recovery |
| `morning-summary.sh` (08:00 timer) | Daily morning summary |
| n8n ← Uptime Kuma webhook | Service down / back up |
| n8n ← Forgejo push webhook | Git push (repo: `FORGEJO_REPO_NAME`) |
| n8n ← NetAlertX webhook | New device, offline / disconnect |

| Command | Description |
|---------|-------------|
| `make telegram-test` | Test message |
| `make telegram-menu` | Panel link buttons |
| `make morning-test` | Send morning summary now |

Bot sends notifications only; it does not reply to incoming messages.

## Passwords

All passwords live in `.env` on the Mac. Services:

| Variable | Service |
|----------|---------|
| `AGH_ADMIN_PASSWORD` | AdGuard |
| `DOZZLE_ADMIN_PASSWORD` | Dozzle |
| `UPTIME_KUMA_ADMIN_PASSWORD` | Uptime Kuma |
| `SYNCTHING_GUI_PASSWORD` | Syncthing |
| `FORGEJO_ADMIN_PASSWORD` | Forgejo |
| `RESTIC_PASSWORD` | Backup |

Generate new password: `openssl rand -base64 18 | tr -d '/+=' | head -c 20`

Post-deploy scripts apply passwords after deploy.

## Backup (3-2-1)

1. **Pi SSD (encrypted data):** Restic via Docker (`pi-gateway-backup.timer` → `backup.sh` → `restic-backup.sh`). Runs as `PI_USER` with `REMOTE_DIR=~/pi-gateway` — never as root (`/home/root/...` is wrong).
2. **Config snapshot:** same timer writes `~/pi-gateway/backups/<stamp>/` (compose + config + env key names; no plaintext secrets).
3. **Mac offsite:** `make backup-pull` or `make backup-cron` → `~/Backups/pi-gateway/`

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
