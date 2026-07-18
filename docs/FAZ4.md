# Faz 4 — Ağ görünürlüğü (NetAlertX)

LAN cihaz envanteri, yeni cihaz ve offline uyarıları.

## Panel

| URL | Açıklama |
|-----|----------|
| https://devices.home | NetAlertX arayüzü (Caddy auth) |

`.env`:

```bash
ENABLE_NETALERTX=true
NETALERTX_PORT=20211
# Opsiyonel — bos ise LAN_SUBNET_CIDR + PI_INTERFACE kullanilir
NETALERTX_SCAN_SUBNETS=
```

## Kurulum

Deploy sırasında otomatik:

1. `netalertx` container (`--profile netalert`, host network)
2. `setup-netalertx.sh` — ARP tarama subnet + n8n webhook
3. n8n workflow `Pi Gateway — NetAlertX Alert`
4. Kuma monitor `devices.home`

Manuel:

```bash
ssh pi 'REMOTE_DIR=~/pi-gateway bash ~/pi-gateway/scripts/pi/setup-netalertx.sh'
```

## İlk çalıştırma

İlk ARP taraması **5–10 dakika** sürebilir. Sonrasında **Devices** listesinde LAN cihazları görünür.

Bilinen cihazları onaylayın / etiketleyin; böylece “yeni cihaz” uyarıları azalır.

## Bildirimler

| Olay | Kanal |
|------|-------|
| Yeni cihaz | n8n → Telegram |
| Offline / disconnect | n8n → Telegram |

NetAlertX içinde doğrudan Telegram **kapalı** — tek hat n8n webhook.

Test:

```bash
make telegram-test   # genel hat
# smoke: n8n-netalert-webhook (deploy sonrasi)
```

## Kuma ile fark

| Araç | Soru |
|------|------|
| Uptime Kuma | Servis ayakta mı? |
| NetAlertX | Ağda hangi cihazlar var? |

## Kapatma

```bash
# .env
ENABLE_NETALERTX=false
make deploy-fast
```

Veri `data/netalertx/` altında kalır.
