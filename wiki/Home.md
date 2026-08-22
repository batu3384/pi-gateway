# Pi Gateway Wiki

Production DNS / home-lab gateway for **Raspberry Pi 4B**: AdGuard + Unbound, Caddy, Forgejo, Syncthing, n8n, monitoring — deployed from a Mac with one pipeline.

**Repo:** [github.com/batu3384/pi-gateway](https://github.com/batu3384/pi-gateway)

## Quick links

| Topic | Page |
|-------|------|
| Install & first boot | [Getting Started](Getting-Started) |
| Design & traffic flow | [Architecture](Architecture) |
| SSD / degraded mode | [Troubleshooting](Troubleshooting) |
| Common questions | [FAQ](FAQ) |
| Threat model & secrets | [Security](Security) |
| **Roadmap (Now / Next / Later)** | [Roadmap](Roadmap) |

## Stack (summary)

| Layer | Component |
|-------|-----------|
| DNS filter | AdGuard Home |
| Recursive DNS | Unbound |
| Reverse proxy | Caddy (`*.home`) |
| Dashboard | Homepage + gateway widget |
| Monitoring | Uptime Kuma, Prometheus, Grafana, systemd health timer |
| Git / sync / backup | Forgejo, Syncthing, Restic (3-2-1 SLA) |
| Security | UFW, fail2ban, optional CrowdSec / Tailscale |

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
- Security: [Security](Security) — no public issues for vulns
