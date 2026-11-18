# Phase 3 — Automation, cache, security, tunnel

> **TLS varsayılan.** Panel URL'leri `https://*.home` — bkz. [OPERATIONS.md](OPERATIONS.md).

## Services

| Service | URL / bind | Notes |
|---------|------------|-------|
| CrowdSec | `127.0.0.1:8082` | SSH attack detection (offline API default; CAPI noise excluded from nightly diary) |
| Cloudflare Tunnel | — | Active when `CLOUDFLARE_TUNNEL_TOKEN` is set |
| n8n (retired / optional) | https://n8n.home | Disabled by default (`ENABLE_N8N=false`); enable only if needed |

## Optional n8n setup (`ENABLE_N8N=true`)

1. Set `ENABLE_N8N=true` and `N8N_ENCRYPTION_KEY` in `.env`, then `make deploy`
2. Open https://n8n.home and create owner account (`executeCommand` + `ssh` nodes are disabled for host isolation)

## CrowdSec

Offline threat intel varsayılan (`CROWDSEC_DISABLE_ONLINE_API=true`). Online API opt-in:
```bash
# .env
CROWDSEC_DISABLE_ONLINE_API=false
make deploy
```

```bash
ssh "$PI_USER@$PI_STATIC_IP" 'docker exec crowdsec cscli metrics'
ssh "$PI_USER@$PI_STATIC_IP" 'docker exec crowdsec cscli decisions list'
```

## Cloudflare Tunnel

See **[docs/CLOUDFLARE-TUNNEL.md](CLOUDFLARE-TUNNEL.md)** (checklist + disable).

1. [Cloudflare Zero Trust](https://one.dash.cloudflare.com/) → Networks → Tunnels
2. Create token → add to `.env` as `CLOUDFLARE_TUNNEL_TOKEN=...`
3. `make deploy` (profile added automatically)

Prefer Tailscale for admin. Public hostname example: `demo.yourdomain.com` → Caddy on localhost.

## Disable

Set `ENABLE_N8N=false` etc. in `.env`, then `make deploy`.

## Ops shortcuts (Mac)

| Command | Description |
|---------|-------------|
| `make diagnose-remote` | Tailscale / SSH / UFW erişim teşhisi |
| `make diagnose-dns` | DNS bypass / AdGuard teşhisi |
| `make recover-stack` | Manuel stack kurtarma |
| `make restore-check` | restic check (Pi + Mac offsite) |
