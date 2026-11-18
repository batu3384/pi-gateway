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
NETALERTX_LISTEN_ADDR=172.17.0.1
# Optional — if empty, LAN_SUBNET_CIDR + PI_INTERFACE are used
NETALERTX_SCAN_SUBNETS=
# Default false (avoids random privacy-MAC notification spam on iOS/Android)
NETALERTX_TELEGRAM_NEW_DEVICE=false
```

## Setup

Automatic during deploy:

1. `netalertx` container (`--profile netalert`, host network bound to `172.17.0.1`)
2. `setup-netalertx.sh` — ARP + AdGuard isimler; isteğe bağlı yeni cihaz Telegram (`NETALERTX_TELEGRAM_NEW_DEVICE=true` ise `sendMessage`, Hermes `getUpdates` değil)
3. Panel: `devices.home` — Gatus monitor aynı servisi izler

Manual:

```bash
ssh pi 'REMOTE_DIR=~/pi-gateway bash ~/pi-gateway/scripts/pi/setup-netalertx.sh'
```

## First run

First ARP scan may take **5–10 minutes**. After that, LAN devices appear in **Devices**.

## Notifications

`NETALERTX_TELEGRAM_NEW_DEVICE=true` açılırsa NetAlertX `TELEGRAM` plugin → Bot API `sendMessage` ile yeni MAC bildirir (varsayılan `false` — telefonların rastgele MAC adresleri bildirim yorgunluğu yaratmasın diye kapalıdır; cihaz listesi her zaman `https://devices.home` panelinde görünür).

Test:

```bash
make telegram-test
python3 scripts/lib/netalert-devices.py --self-check
```

## Difference from Gatus

| Tool | Question |
|------|----------|
| Gatus | Is the service / SLO healthy? |
| NetAlertX | Which devices are on the network? |

## Disable

```bash
# .env
ENABLE_NETALERTX=false
make deploy-fast
```

Data remains under `data/netalertx/`.
