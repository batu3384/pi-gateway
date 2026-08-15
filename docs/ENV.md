# Environment Variables (.env)

## Required (before deploy)

| Variable | Description |
|----------|-------------|
| `PI_HOST` / `PI_STATIC_IP` | Pi LAN address (service bind, DNS) |
| `PI_DEPLOY_HOST` | Optional SSH/deploy host (e.g. Tailscale `100.x` when LAN unreachable) |
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
| `SSD_PROBE_TIMEOUT_SEC` | `3` | Write-probe timeout for stale/hung `/mnt/ssd` |
| `SSD_USB_RESET_MAX` | `3` | Soft-reset attempts per window (JMicron `152d:0583`) |
| `SSD_USB_RESET_WINDOW_SEC` | `900` | Soft-reset rate-limit window |
| `SSD_USB_HOST_PORT` | `0` | `0` = hatirlanan + USB3 once; `>0` = once bu port numarasi |
| `SSD_USB_PORT_SCAN_MAX` | `1` | Hatirlanan porttan sonra ayni tick'te kac ekstra port |
| `SSD_USB_CYCLE_ON_HANG` | `true` | USB enumerate olsa da I/O oluyse port cycle |
| `SSD_USB_STORAGE_REBIND` | `true` | Port power oncesi usb-storage unbind/bind |
| `SSD_USB_XHCI_REBIND` | `false` | Opt-in xHCI PCI rebind (all USB3 collateral) |
| `SSD_HOTPLUG_DEBOUNCE_SEC` | `30` | Debounce after SSD restore |
| `SSD_USB_RESET_REBOOT` | `false` | If `true`, reboot after reset budget exhausted (last resort) |
| `SSD_USB_AUTHORIZED_RESET` | `false` | If `true`, USB `authorized` 0→1 cycle (risky on JMS583) |
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
| `RESTIC_REPOSITORY` | Path on SSD (not offsite by itself) |
| `MAC_BACKUP_DEST` | Mac `backup-pull` destination |
| `OFFSITE_BACKUP_MAX_AGE_DAYS` | Default `7`; `0` disables age check |
| `WEAK_BACKUP_OK` | `yes` = allow stale offsite in doctor |

SSD restic alone is **not** 3-2-1. Run `make backup-pull` / `make backup-cron`. See [ADR-004](adr/004-backup-3321.md).

## TLS

| Variable | Default | Description |
|----------|---------|-------------|
| `ENABLE_TLS` | `true` | Caddy HTTPS for `*.home` |
| `WEAK_TLS_OK` | (unset) | Required to set `ENABLE_TLS=false` |
| `N8N_SECURE_COOKIE` | `true` | Must be true when TLS on |

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
| `NETALERTX_PORT` | `20211` | UI (loopback; Caddy `devices.home`) |
| `NETALERTX_LISTEN_ADDR` | `172.17.0.1` | Host-network listen on docker0 (Caddy bridge proxy). Avoid `0.0.0.0`. |
| `NETALERTX_SCAN_SUBNETS` | (empty) | ARP scan; if empty, `LAN_SUBNET_CIDR` + `PI_INTERFACE` |
| `NETALERTX_PASSWORD` | (empty → `AGH_ADMIN_PASSWORD`) | NetAlertX UI password |

Details: `docs/FAZ4.md`
