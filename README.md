# Pi Gateway

Production DNS / home-lab gateway for **Raspberry Pi 4B**.

AdGuard + Unbound DNS, Caddy reverse proxy, n8n, monitoring — deployed from a Mac with one pipeline.

## Stack

| Layer | Component |
|-------|-----------|
| DNS filter | AdGuard Home |
| Recursive DNS | Unbound |
| Reverse proxy | Caddy (`*.home`) |
| Dashboard | Homepage |
| Monitoring | Uptime Kuma + host health timer |
| Logs | Dozzle |
| Backup | Restic |
| Network inventory | NetAlertX |
| Security | UFW + CrowdSec (SSH) + Tailscale |

## Requirements

- **Mac (or Linux):** Docker, SSH with key auth (`ssh-copy-id`), `python3`, `rsync`
- **Pi 4B:** Ethernet, adequate PSU; **USB SSD required** for default hybrid storage (`/mnt/ssd` data)
- Strong passwords in `.env` (min 12 chars; no `CHANGE_ME*` placeholders)

## Quick start

```bash
git clone https://github.com/batu3384/pi-gateway.git
cd pi-gateway
cp .env.example .env
# Edit .env: passwords, PI_USER; then: make tls-certs
# Plug USB SSD into the Pi before install

make install   # doctor → discover → render → validate → deploy
make backup-cron   # offsite SLA (3-2-1)
make status
```

After install (router-dns mode): set the router DHCP DNS server to the Pi static IP once.

Full walkthrough: **[INSTALL.md](INSTALL.md)**

## Documentation

| Doc | Topic |
|-----|--------|
| [INSTALL.md](INSTALL.md) | Install & first boot |
| [docs/ARCHITECTURE.md](docs/ARCHITECTURE.md) | Design & traffic flow |
| [docs/adr/](docs/adr/README.md) | Architecture decisions |
| [docs/SCRIPTS.md](docs/SCRIPTS.md) | Script tiers (core/ops/experimental) |
| [docs/ENV.md](docs/ENV.md) | Environment variables |
| [docs/OPERATIONS.md](docs/OPERATIONS.md) | Day-to-day ops |
| [docs/SECURITY.md](docs/SECURITY.md) | Security model |
| [docs/CLOUDFLARE-TUNNEL.md](docs/CLOUDFLARE-TUNNEL.md) | Optional public tunnel |
| [docs/DNS-BLOCKING.md](docs/DNS-BLOCKING.md) | Ad blocking |
| [docs/TAILSCALE.md](docs/TAILSCALE.md) | Remote access |
| [docs/RESTORE.md](docs/RESTORE.md) | Restic restore |
| [docs/SSD-INSTALL.md](docs/SSD-INSTALL.md) | Storage / SSD setup |

## Useful commands

```bash
make doctor      # local prerequisite checks
make validate    # render + contract tests (Pi can be offline)
make test        # alias for validate (CI / runtime-check)
make discover    # network discovery → writes .env
make deploy      # push stack to Pi
make dns-test    # DNS checks from Mac
make backup-pull # offsite restic copy to Mac
make restore-check # restic check (Pi + Mac offsite)
make diagnose-remote # Tailscale/SSH/UFW teşhisi
make recover-stack   # manuel stack kurtarma
```

## Security

- Never commit `.env`
- Report vulnerabilities via [.github/SECURITY.md](.github/SECURITY.md)
- Before making the repo public: rotate any credentials that ever leaked in chat/logs — see [docs/SECURITY.md](docs/SECURITY.md)

## License

MIT — see [LICENSE](LICENSE).
