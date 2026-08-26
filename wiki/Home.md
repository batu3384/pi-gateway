# Pi Gateway Wiki

Production DNS / home-lab gateway for **Raspberry Pi 4B**: AdGuard + Unbound, Caddy, n8n, monitoring — deployed from a Mac with one pipeline.

**Repo:** [github.com/batu3384/pi-gateway](https://github.com/batu3384/pi-gateway)

## Quick links

| Topic | Page |
|-------|------|
| Install & first boot | [Getting Started](Getting-Started.md) |
| Design & traffic flow | [Architecture](Architecture.md) |
| SSD / degraded mode | [Troubleshooting](Troubleshooting.md) |
| Common questions | [FAQ](FAQ.md) |
| Threat model & secrets | [Security](Security.md) |
| **Roadmap (Now / Next / Later)** | [Roadmap](Roadmap.md) |

## Stack (summary)

| Layer | Component |
|-------|-----------|
| DNS filter | AdGuard Home |
| DNS resolver | Unbound (DoT :853) |
| Reverse proxy | Caddy (`*.home`) |
| Dashboard | Homepage + gateway widget |
| Monitoring | Uptime Kuma, Prometheus, Grafana, systemd health timer |
| Backup | Restic (3-2-1 SLA) |
| Security | UFW, CrowdSec / Tailscale |

## Useful commands (Mac)

```bash
make install    # doctor → discover → render → validate → deploy
make validate   # contract tests (Pi can be offline)
make status     # Pi summary
make test-remote # health + smoke on Pi
```

## Repo docs (not duplicated on wiki)

Deep reference stays in git: `docs/adr/`, `docs/ENV.md`, `docs/SSD-INSTALL.md`, `docs/runbooks/`.

## Report issues

- Bugs / features: [GitHub Issues](https://github.com/batu3384/pi-gateway/issues)
- Security: [Security](Security.md) — no public issues for vulns
