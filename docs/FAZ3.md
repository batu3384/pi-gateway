# Phase 3 — Automation, cache, security, tunnel

> **TLS varsayılan.** Panel URL'leri `https://*.home` — bkz. [OPERATIONS.md](OPERATIONS.md).

## Services

| # | Service | URL / bind | Notes |
|---|---------|------------|-------|
| 5 | CrowdSec | `127.0.0.1:8082` | SSH attack detection (offline API default) |
| 9 | Redis | `127.0.0.1:6379` | **Kapalı varsayılan**; açılırsa `REDIS_PASSWORD` zorunlu |
| 10 | n8n | https://n8n.home | Automation / webhooks |
| 2 | Cloudflare Tunnel | — | Active when `CLOUDFLARE_TUNNEL_TOKEN` is set |

## n8n first-time setup

1. https://n8n.home
2. Create owner account on first launch
3. `N8N_ENCRYPTION_KEY` in `.env` must stay fixed — do not change it

## Redis (opt-in)

Varsayılan `ENABLE_REDIS=false` (tüketici yok). Açmak için `.env` → `ENABLE_REDIS=true` ve güçlü `REDIS_PASSWORD`, sonra `make deploy`.

Test from Mac (Redis açıkken):
```bash
ssh -L 6379:127.0.0.1:6379 "$PI_USER@$PI_STATIC_IP"
redis-cli -h 127.0.0.1 -a "$REDIS_PASSWORD" ping
```

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
