# FAQ

## Do I need an SSD?

**Yes** for default hybrid mode. Application data lives on `/mnt/ssd`. SD-only fallback exists for DNS degraded mode but not for full stack long-term.

## Can I run without Tailscale?

Yes. LAN access via `*.home` + mkcert. Tailscale is optional (`docs/TAILSCALE.md`).

## Why is Forgejo down but DNS works?

**Degraded mode** — SSD missing or unhealthy. Core-dns (Unbound + AdGuard) stays on SD; app containers stop. See [Troubleshooting](Troubleshooting).

## Is JMicron USB SSD reliable on Pi 4?

Often **no** for 24/7 (`152d:0583`). Software recovery helps; ASMedia adapter is the documented permanent fix (`docs/SSD-JMICRON-FIX.md`).

## Where are secrets?

`.env` on Pi and Mac clone — **never committed**. See [Security](Security).

## How do I update the stack?

```bash
git pull
make deploy
```

Canary: `scripts/pi/canary-compose-update.sh` on Pi.

## How do backups work?

Daily Restic on SSD; offsite via `make backup-pull` / B2/R2 (`docs/adr/004-backup-3321.md`). Degraded → backup skips (by design).

## What is `make validate` vs `make test-remote`?

| Command | Where | Checks |
|---------|-------|--------|
| `make validate` | Mac | shellcheck, compose, static contracts |
| `make test-remote` | SSH to Pi | health-check + smoke-test |

## Unified login?

Default `UNIFIED_LOGIN=true` — `AGH_ADMIN_*` passwords sync to Dozzle, Kuma, Forgejo, Syncthing via deploy.

## Wiki vs repo docs?

Wiki = operator overview. Deep reference (`ENV.md`, ADRs, runbooks) stays in git.

## Roadmap?

See [Roadmap](Roadmap) — not duplicated here.
