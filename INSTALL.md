# Install — Pi Gateway

Automated Mac → Raspberry Pi deploy for a production DNS / home-lab stack.

## Requirements

- **Mac:** Docker Desktop (or Engine), SSH **with key auth** (`ssh-copy-id`), rsync, python3
- **Pi 4B:** OS on SD card; ethernet; 5V/3A+ PSU
- **USB SSD (required for default hybrid mode):** plugged into a USB 3.0 port before `make install`. Bootstrap formats/mounts it at `/mnt/ssd` and stores all app data there. Without the SSD, install **exits with an error**.
- `.env` with strong passwords (min 12 characters; no `CHANGE_ME*` placeholders)

Password-only SSH is not supported for deploy (non-interactive). Use: `ssh-copy-id "$PI_USER@$PI_HOST"`.

Default storage: **hybrid** — SD = OS (boot + root), SSD = `/mnt/ssd` data. See [docs/SSD-INSTALL.md](docs/SSD-INSTALL.md).

## Quick install (Pi online)

```bash
cd /path/to/pi-gateway
cp .env.example .env
# Edit .env: AGH_ADMIN_PASSWORD, PI_USER, other service passwords, optional TAILSCALE_AUTHKEY
make install   # runs doctor → discover → render → validate → deploy
```

`make install`:

1. Uses `PI_HOST` if set; otherwise falls back to `PI_STATIC_IP`; otherwise prompts for a temporary DHCP IP
2. Runs `make doctor` (fails on missing tools / placeholder passwords)
3. Discovers network, renders configs, validates, deploys

## What is automated

| Step | Automated |
|------|-----------|
| Prerequisite checks (`doctor`) | Yes (via `make install`) |
| Network discovery (gateway, subnet, static IP) | Yes |
| dhcpcd static IP | Yes |
| SSD data disk at `/mnt/ssd` | Yes (USB SSD must be attached) |
| Docker + compose stack | Yes |
| AdGuard + Unbound + Homepage + Uptime Kuma | Yes |
| Optional profiles (Caddy, n8n, …) | Yes (from `.env` flags) |
| Post-deploy service setup + smoke test | Yes |

## One-time manual steps

### router-dns mode (default)

Router admin → DHCP DNS1 = Pi static IP. ZTE H3600P still injects DNS2=gateway (LAN `:53` ads; IP filter is FORWARD). Mac: `make mac-dns` (LAN only; hotspot’a yazmaz). See [docs/DNS-BLOCKING.md](docs/DNS-BLOCKING.md).

### adguard-dhcp mode

Do **not** use on ZTE H3600P — DHCP relay swallows LAN DISCOVER, house loses IP. Other routers only: modem DHCP off **after** AdGuard `:67` is proven. Rollback: modem DHCP **on first**. [docs/ADGUARD-DHCP.md](docs/ADGUARD-DHCP.md)

## Remote access

1. Create a Tailscale auth key: https://login.tailscale.com/admin/settings/keys  
2. Set `TAILSCALE_AUTHKEY=...` in `.env`  
3. After deploy: Tailscale admin → MagicDNS / split DNS as needed  

Details: [docs/TAILSCALE.md](docs/TAILSCALE.md)

**SSH:** deploy sonrası şifre kapalı (yalnız key). Key kaybı: HDMI/konsol veya SD `userconf` / raspi-config; `sudo rm /etc/ssh/sshd_config.d/00-pi-gateway-ssh.conf && sudo systemctl reload ssh`

## Commands

```bash
make doctor     # prerequisite checks only
make validate   # config validation (Pi may be offline)
make discover   # network discovery only
make render     # generate configs from .env
make deploy     # sync + bring stack up
make install    # doctor + full pipeline
make status     # remote status
make dns-test   # DNS checks from Mac
```

## Troubleshooting

```bash
ssh "$PI_USER@$PI_STATIC_IP" 'cd ~/pi-gateway/compose && docker compose ps'
ssh "$PI_USER@$PI_STATIC_IP" 'cd ~/pi-gateway/compose && docker compose logs -f adguard'
ssh "$PI_USER@$PI_STATIC_IP" 'sudo journalctl -t pi-gateway-health -n 20'
```

**SSD not found:** plug USB SSD into USB 3.0, confirm `lsblk` on the Pi, re-run `make install`.

Architecture: [docs/ARCHITECTURE.md](docs/ARCHITECTURE.md)  
Operations: [docs/OPERATIONS.md](docs/OPERATIONS.md)
