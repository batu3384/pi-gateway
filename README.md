# Pi Gateway

Production DNS / home-lab gateway for **Raspberry Pi 4B**.

AdGuard + Unbound DNS, Caddy reverse proxy, Forgejo, Syncthing, n8n, monitoring — deployed from a Mac with one pipeline.

## Stack

| Layer | Component |
|-------|-----------|
| DNS filter | AdGuard Home |
| Recursive DNS | Unbound |
| Reverse proxy | Caddy (`*.home`) |
| Dashboard | Homepage |
| Monitoring | Uptime Kuma + host health timer |
| Logs | Dozzle |
| Git | Forgejo |
| Sync / backup | Syncthing + Restic |
| Network inventory | NetAlertX |
| Security | UFW, fail2ban, optional CrowdSec / Tailscale |

## Requirements

- **Mac (or Linux):** Docker, SSH, `python3`, `rsync`
- **Pi 4B:** Ethernet, adequate PSU; **USB SSD required** for default hybrid storage (`/mnt/ssd` data)
- Strong passwords in `.env` (min 12 chars; no `CHANGE_ME*` placeholders)

## Quick start

```bash
git clone https://github.com/batu3384/pi-gateway.git
cd pi-gateway
cp .env.example .env
# Edit .env: AGH_ADMIN_PASSWORD, PI_USER, service passwords, optional Tailscale
# Plug USB SSD into the Pi before install

make install   # doctor → discover → render → validate → deploy
make status
```

After install (router-dns mode): set the router DHCP DNS server to the Pi static IP once.

Full walkthrough: **[INSTALL.md](INSTALL.md)**

## Documentation

| Doc | Topic |
|-----|--------|
| [INSTALL.md](INSTALL.md) | Install & first boot |
| [docs/ARCHITECTURE.md](docs/ARCHITECTURE.md) | Design & traffic flow |
| [docs/ENV.md](docs/ENV.md) | Environment variables |
| [docs/OPERATIONS.md](docs/OPERATIONS.md) | Day-to-day ops |
| [docs/SECURITY.md](docs/SECURITY.md) | Security model |
| [docs/DNS-BLOCKING.md](docs/DNS-BLOCKING.md) | Ad blocking |
| [docs/TAILSCALE.md](docs/TAILSCALE.md) | Remote access |
| [docs/RESTORE.md](docs/RESTORE.md) | Restic restore |
| [docs/SSD-INSTALL.md](docs/SSD-INSTALL.md) | Storage / SSD setup |

## Useful commands

```bash
make doctor      # local prerequisite checks
make validate    # render + contract tests (Pi can be offline)
make discover    # network discovery → writes .env
make deploy      # push stack to Pi
make dns-test    # DNS checks from Mac
make backup-pull # offsite restic copy to Mac
```

## Security

- Never commit `.env`
- Report vulnerabilities via [.github/SECURITY.md](.github/SECURITY.md)
- Before making the repo public: rotate any credentials that ever leaked in chat/logs — see [docs/SECURITY.md](docs/SECURITY.md)

## License

MIT — see [LICENSE](LICENSE).
