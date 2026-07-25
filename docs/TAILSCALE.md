# Tailscale Remote Access

## Setup (Pi)

`setup-tailscale-remote.sh` runs during deploy. Manual:

```bash
ssh pi 'REMOTE_DIR=~/pi-gateway bash ~/pi-gateway/scripts/pi/setup-tailscale-remote.sh'
```

## Mac / iPhone

1. Install the Tailscale app
2. Sign in to the same tailnet
3. Approve Pi: subnet route `192.168.1.0/24`

## DNS (`*.home` remotely)

Tailscale Admin → DNS → Nameservers:

- Split DNS: `home` → Pi Tailscale IP (`100.x.x.x`)
- Enable **Override local DNS**

## Tailscale Serve (recommended — remote Telegram links)

On phone, `https://gateway.home` does not trust mkcert certs. Instead:

1. Enable Serve in Admin: `/f/serve` link from deploy or ACL
2. On Pi: `bash scripts/pi/setup-tailscale-serve.sh`
3. Telegram menu **🌐 Remote** buttons: `https://pi-gateway.tailXXXX.ts.net/p/dns` etc.

```bash
make telegram-menu   # or on Pi: scripts/pi/telegram-menu.sh
```

Diagnostics: `bash scripts/pi/diagnose-remote-access.sh`

## ACL (recommended)

`make tailscale-acl` — requires `TAILSCALE_ACL_OWNER` in `.env` (Tailscale email).
Template: `config/tailscale/acl.hujson.example` → local `config/tailscale/acl.hujson` (gitignored, do not commit).

Manual: copy template to [Access Controls](https://login.tailscale.com/admin/acls).

- Tag Pi: `tag:pi-gateway`
- Your devices: `tag:owner-device`
- Guest devices cannot reach Pi

## SSH

```bash
ssh pi-ts          # Tailscale IP
ssh "$PI_USER@100.x.x.x"
```

## Security note

UFW allows only 22/80/443 on `tailscale0`. Admin panels are reached via Caddy (`*.home`).
