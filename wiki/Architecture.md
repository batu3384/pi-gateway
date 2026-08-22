# Architecture

Single-node home DNS + dev server on Raspberry Pi 4B. Infrastructure-as-code: rendered configs, contract tests, systemd health timers.

## Design goals

- Zero manual AdGuard/Unbound edits after deploy
- Self-healing stack (`recover-stack.sh`, healthchecks, optional autoheal)
- **Hybrid storage** — SD root, SSD data; degraded mode keeps DNS alive
- TLS on by default (`ENABLE_TLS=true`)
- Offsite backup SLA (`make backup-pull`, Restic)

## Traffic flow

```
Client DNS query
       │
       ▼
 AdGuard Home (:53, host network)
       │ blocklists + rewrites
       ▼
 Unbound (:5335, recursive)
       │
       ▼
 Internet
```

HTTP(S) panels: **Caddy** terminates TLS for `*.home` → Docker services.

## Compose tiers

| Tier | Services | Role |
|------|----------|------|
| **dns-core** | unbound, adguard | Always up — even SSD degraded |
| **panels** | caddy, homepage, uptime-kuma, dozzle | `*.home` UI |
| **automation** | forgejo, syncthing, n8n, redis, netalertx, crowdsec | SSD data (best-effort) |
| **monitoring** | prometheus, grafana, node-exporter | Profile `monitoring` |
| **edge** | cloudflare tunnel, watchtower | Opt-in |

Profiles: `ENABLE_*` in `.env` → `scripts/lib/compose-profiles.sh`.

## Storage FSM (SSD)

```
healthy ──drop──► degraded (core-dns on SD)
    ▲                    │
    └── remount + hotplug restore ──┘
```

Software path: `ssd-health.sh` → port cycle / xHCI / ghost cleanup → `ssd-hotplug-handler.sh`.

Runbook detail: repo `docs/runbooks/SSD-FSM.md`.

## Health & notify

| Timer | Script | Role |
|-------|--------|------|
| `pi-gateway-health.timer` | `health-check.sh` | DNS, disk, SLA (soft-fail for backup) |
| `pi-ssd-health.timer` | `ssd-health.sh` | SSD liveness / soft-reset |
| `pi-ssd-watch.path` | hotplug handler | udev SSD add/remove |

Telegram: edge-triggered transitions (`scripts/lib/notify.sh`).

## ADRs

Architecture decisions: [docs/adr/](https://github.com/batu3384/pi-gateway/tree/master/docs/adr).

| ADR | Topic |
|-----|--------|
| 001 | Hybrid storage |
| 002 | DNS modes |
| 003 | Security layers |
| 004 | Backup 3-2-1 |
| 005 | Remote access |

Script map: repo `docs/SCRIPTS.md`.
