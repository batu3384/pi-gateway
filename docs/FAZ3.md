# Phase 3 — Automation, cache, security, tunnel

## Services

| # | Service | URL | Notes |
|---|---------|-----|-------|
| 5 | CrowdSec | `127.0.0.1:8082` | SSH attack detection (alongside fail2ban) |
| 9 | Redis | `127.0.0.1:6379` | Pi only (SSH tunnel) |
| 10 | n8n | http://n8n.home | Automation / webhooks |
| 2 | Cloudflare Tunnel | — | Active when `CLOUDFLARE_TUNNEL_TOKEN` is set |

## n8n first-time setup

1. http://n8n.home or `http://PI_STATIC_IP:5678`
2. Create owner account on first launch
3. `N8N_ENCRYPTION_KEY` in `.env` must stay fixed — do not change it

## Redis (test from Mac)

```bash
ssh -L 6379:127.0.0.1:6379 "$PI_USER@$PI_STATIC_IP"
redis-cli -h 127.0.0.1 ping
```

## CrowdSec

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
