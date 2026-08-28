# Phase 4 — Network visibility (NetAlertX)

LAN device inventory and Telegram alert on new MAC.

## Panel

| URL | Description |
|-----|-------------|
| https://devices.home | NetAlertX UI (NetAlertX uygulama parolası; Caddy basic_auth yok) |

`.env`:

```bash
ENABLE_NETALERTX=true
NETALERTX_PORT=20211
NETALERTX_LISTEN_ADDR=127.0.0.1
# Optional — if empty, LAN_SUBNET_CIDR + PI_INTERFACE are used
NETALERTX_SCAN_SUBNETS=
```

## Setup

Automatic during deploy:

1. `netalertx` container (`--profile netalert`, host network)
2. `setup-netalertx.sh` — ARP + AdGuard isimler; yeni cihaz Telegram (`sendMessage`, Hermes `getUpdates` değil)
3. Panel: `devices.home` — Kuma monitor aynı URL

Manual:

```bash
ssh pi 'REMOTE_DIR=~/pi-gateway bash ~/pi-gateway/scripts/pi/setup-netalertx.sh'
```

## First run

First ARP scan may take **5–10 minutes**. After that, LAN devices appear in **Devices**.

## Notifications

Yeni MAC: NetAlertX `TELEGRAM` plugin → Bot API `sendMessage` (aynı token, Hermes inbox ayrı). Offline spam yok (`NTFPRCS` yalnız `new_devices`).

Test:

```bash
make telegram-test
python3 scripts/lib/netalert-devices.py --self-check
```

## Difference from Kuma

| Tool | Question |
|------|----------|
| Uptime Kuma | Is the service up? |
| NetAlertX | Which devices are on the network? |

## Disable

```bash
# .env
ENABLE_NETALERTX=false
make deploy-fast
```

Data remains under `data/netalertx/`.
