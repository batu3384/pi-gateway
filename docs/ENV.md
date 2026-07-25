# Environment Variables (.env)

## Required (before deploy)

| Variable | Description |
|----------|-------------|
| `PI_HOST` / `PI_STATIC_IP` | Pi address |
| `AGH_ADMIN_PASSWORD` | AdGuard admin (≥12 characters) |
| `LAN_GATEWAY`, `LAN_SUBNET_CIDR` | Filled by `discover-remote.sh` |

## DNS / AdGuard

| Variable | Default |
|----------|---------|
| `ADGUARD_BOOT_WAIT_SEC` | 180 |
| `ADGUARD_MIN_FILTER_RULES` | 100000 |
| `ADGUARD_MIN_REWRITES` | 7 |
| `ADGUARD_BLOCKED_TTL` | 60 |

## Security

| Variable | Description |
|----------|-------------|
| `UFW_ADMIN_EXPOSURE` | `full` or `caddy-only` |
| `TELEGRAM_BOT_TOKEN` | @BotFather token |
| `TELEGRAM_CHAT_ID` | Notification channel |
| `CROWDSEC_BOUNCER_KEY` | Written automatically on first setup |

## Syncthing

| Variable | Description |
|----------|-------------|
| `SYNCTHING_MAC_DEVICE_ID` | Mac device ID |
| `SYNCTHING_GUI_USER` / `SYNCTHING_GUI_PASSWORD` | Web UI |

## SSD / storage

| Variable | Default | Description |
|----------|---------|-------------|
| `STORAGE_TYPE` | `hybrid` | **Production:** SD root + SSD data (`/mnt/ssd`). `ssd-data` alias. |
| `DNS_DEGRADED_ON_SSD_LOSS` | `true` | **Recommended.** On SSD loss, Unbound+AdGuard on SD (core-dns). Forgejo/n8n stay down. |
| `STORAGE_FALLBACK_SD` | `false` | Back-compat: if `true`, enables same DNS degraded path. Full app stack still requires SSD. |
| `ENABLE_DOCKER_SSD` | `false` | `true`: Docker `data-root` on SSD; I/O risk on JMicron USB |
| `DOCKER_SSD_ROOT` | `/mnt/ssd/docker` | Target when `ENABLE_DOCKER_SSD=true` |
| `STACK_RECOVER_COOLDOWN_SEC` | `180` | Auto-recover wait after compose up |
| `STACK_BOOT_GRACE_SEC` | `120` | Post-boot recover delay |

Experimental `ssd-root`: `docs/SSD-ROOT.md` + `scripts/mac/migrate-sd-boot-ssd-root.sh`

## Backup

| Variable | Description |
|----------|-------------|
| `ENABLE_RESTIC` | true/false |
| `RESTIC_PASSWORD` | Repo password |
| `RESTIC_REPOSITORY` | Path on SSD |
| `MAC_BACKUP_DEST` | Mac `backup-pull` destination |

## Watchtower

`ENABLE_WATCHTOWER=true` and:

```
WATCHTOWER_NOTIFICATION_URL=telegram://TOKEN@telegram?chats=CHAT_ID
```

Full list: `.env.example`

## n8n

| Variable | Description |
|----------|-------------|
| `N8N_ENCRYPTION_KEY` | Credential encryption (≥32 chars; `openssl rand -hex 24`) |
| `N8N_WEBHOOK_SECRET` | Webhook URL suffix (Kuma, Forgejo) |
| `N8N_KUMA_WEBHOOK_URL` | Optional; auto-built from secret if empty |
| `N8N_FORGEJO_WEBHOOK_URL` | Optional; auto-built from secret if empty |

If `N8N_ENCRYPTION_KEY` is empty on Pi, `ensure-n8n-encryption-key.sh` generates it during post-deploy. **Do not change** — existing n8n credentials become unreadable.

## NetAlertX (network inventory)

| Variable | Default | Description |
|----------|---------|-------------|
| `ENABLE_NETALERTX` | `true` | NetAlertX container + setup |
| `NETALERTX_PORT` | `20211` | UI (localhost only; Caddy `devices.home`) |
| `NETALERTX_SCAN_SUBNETS` | (empty) | ARP scan; if empty, `LAN_SUBNET_CIDR` + `PI_INTERFACE` |
| `NETALERTX_PASSWORD` | (empty → `AGH_ADMIN_PASSWORD`) | NetAlertX UI password |

Details: `docs/FAZ4.md`
