# Phase 4 — Network visibility (NetAlertX)

LAN device inventory, new-device and offline alerts.

## Panel

| URL | Description |
|-----|-------------|
| https://devices.home | NetAlertX UI (Caddy auth) |

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
2. `setup-netalertx.sh` — ARP scan subnet; container webhook off (`NETALERT_NOTIFY_VIA=hermes`)
3. Cihaz envanteri: NetAlertX panel (`devices.home`) — Telegram yeni/offline cron kaldırıldı
4. Kuma monitor `devices.home`

Manual:

```bash
ssh pi 'REMOTE_DIR=~/pi-gateway bash ~/pi-gateway/scripts/pi/setup-netalertx.sh'
```

## First run

First ARP scan may take **5–10 minutes**. After that, LAN devices appear in **Devices**.

## Notifications

Telegram yeni-cihaz / offline / saatlik sistem gözcü cron’ları **kaldırıldı**. Envanter için panel: https://devices.home

Test:

```bash
make telegram-test   # general path
python3 scripts/lib/netalert-devices.py --self-check
# smoke: netalert-hermes-poll (after deploy)
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
