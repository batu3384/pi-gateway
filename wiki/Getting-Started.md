# Getting Started

## Requirements

| | |
|---|---|
| **Mac (or Linux)** | Docker, SSH key auth, `python3`, `rsync`, `gh` (wiki sync only) |
| **Pi 4B** | Ethernet, adequate PSU, **USB SSD** for hybrid data (`/mnt/ssd`) |
| **Secrets** | Strong passwords in `.env` — no `CHANGE_ME*` placeholders |

## Install (Mac → Pi)

```bash
git clone https://github.com/batu3384/pi-gateway.git
cd pi-gateway
cp .env.example .env
# Edit .env: PI_USER, passwords, LAN_DOMAIN
make tls-certs          # mkcert for *.home
# Attach USB SSD to Pi before install

make install            # doctor → discover → render → validate → deploy
make backup-cron        # optional offsite SLA
make status
```

Full walkthrough: repo [`INSTALL.md`](https://github.com/batu3384/pi-gateway/blob/master/INSTALL.md).

## After install

1. **Router DNS** — point DHCP DNS to Pi static IP (`PI_STATIC_IP` in `.env`).
2. **Panels** — `https://gateway.home`, `https://dns.home`, `https://status.home` (TLS default).
3. **Trust CA on Mac** — `make trust-ca` if browser warns on mkcert.
4. **Remote** — optional Tailscale: `docs/TAILSCALE.md` in repo.

## Validate without Pi

```bash
make validate   # shellcheck + compose + contract tests
make test       # alias
```

## Hybrid storage (default)

- **SD** — boot + root OS
- **SSD** — application data (`/mnt/ssd/pi-gateway-data`)

If SSD drops, stack enters **degraded** (DNS on SD only). See [Troubleshooting](Troubleshooting.md).

## Next steps

| Goal | Doc (repo) |
|------|----------------|
| Backup (Restic) | `docs/FAZ2.md` |
| n8n / CrowdSec | `docs/FAZ3.md` |
| NetAlertX | `docs/FAZ4.md` |
| Env reference | `docs/ENV.md` |
