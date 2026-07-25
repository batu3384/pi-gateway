# Install — Pi Gateway

Automated Mac → Raspberry Pi deploy for a production DNS / home-lab stack.

## Requirements

- **Mac:** Docker Desktop (or Engine), SSH, rsync, python3
- **Pi 4B:** OS on SD (hybrid) or SSD; ethernet; 5V/3A+ PSU
- `.env` with a strong `AGH_ADMIN_PASSWORD` (min 12 characters)

Default storage model: **hybrid** — SD holds boot/root, USB SSD holds `/mnt/ssd` application data. See [docs/SSD-INSTALL.md](docs/SSD-INSTALL.md).

## Quick install (Pi online)

```bash
cd /path/to/pi-gateway
cp .env.example .env
# Edit .env: passwords, PI_USER, optional TAILSCALE_AUTHKEY
make doctor
make install
```

`make install` will prompt for a temporary Pi IP if `PI_HOST` / `PI_STATIC_IP` are unset, or use values already in `.env`.

## What is automated

| Step | Automated |
|------|-----------|
| Network discovery (gateway, subnet, static IP) | Yes |
| dhcpcd static IP | Yes |
| systemd-resolved port 53 fix | Yes |
| Docker + compose stack | Yes |
| AdGuard admin + Unbound upstream | Yes |
| DNS rewrites (`*.home`) | Yes |
| Homepage + Uptime Kuma | Yes |
| Caddy reverse proxy | Yes |
| Host hardening hooks (log2ram, sysctl, timers) | Yes |
| Daily backup timer (if Restic enabled) | Yes |
| Tailscale (if auth key set) | Yes |
| Post-deploy smoke test | Yes |

## One-time manual steps

### router-dns mode (default)

Router admin → DHCP / DNS → primary DNS = Pi static IP (leave secondary empty if possible).

### adguard-dhcp mode (full automation)

In `.env`: `NETWORK_MODE=adguard-dhcp`. Disable DHCP on the router so AdGuard serves DNS to all clients.

## Remote access

1. Create a Tailscale auth key: https://login.tailscale.com/admin/settings/keys  
2. Set `TAILSCALE_AUTHKEY=...` in `.env`  
3. After deploy: Tailscale admin → MagicDNS / split DNS as needed  

Details: [docs/TAILSCALE.md](docs/TAILSCALE.md)

## Commands

```bash
make doctor     # prerequisite checks
make validate   # config validation (Pi may be offline)
make discover   # network discovery only
make render     # generate configs from .env
make deploy     # sync + bring stack up
make install    # full pipeline
make status     # remote status
make dns-test   # DNS checks from Mac
```

## Troubleshooting

```bash
ssh "$PI_USER@$PI_STATIC_IP" 'cd ~/pi-gateway/compose && docker compose ps'
ssh "$PI_USER@$PI_STATIC_IP" 'cd ~/pi-gateway/compose && docker compose logs -f adguard'
ssh "$PI_USER@$PI_STATIC_IP" 'sudo journalctl -t pi-gateway-health -n 20'
```

Architecture: [docs/ARCHITECTURE.md](docs/ARCHITECTURE.md)  
Operations: [docs/OPERATIONS.md](docs/OPERATIONS.md)
