# Cloudflare Tunnel runbook

Optional public edge. Prefer **Tailscale** (ADR-005). Only enable when you need a public hostname.

## Preconditions

1. Tailscale or LAN admin access still works (rollback path).
2. `ENABLE_TLS=true` and Caddy healthy on Pi (`https://gateway.home`).
3. Cloudflare Zero Trust tunnel created; token ready.

## Enable

1. Zero Trust → Networks → Tunnels → Create.
2. Public hostnames: **only** what you need (e.g. `status.example.com` → `http://127.0.0.1:80` or HTTPS to Caddy).
3. Do **not** publish `dns.home` / AdGuard, Syncthing `:22000`, Redis, or raw service ports.
4. Set in `.env`:

```bash
CLOUDFLARE_TUNNEL_TOKEN=...
```

5. `make validate && make deploy` (profile `cloudflare` auto-enables when token set).

## Checklist (before go-live)

- [ ] Hostname list reviewed (minimal)
- [ ] Cloudflare Access policy on admin paths (recommended)
- [ ] UFW still `caddy-only`; no WAN port forwards on router
- [ ] Image pinned (`cloudflare/cloudflared:2025.11.1` — bump via Dependabot)
- [ ] Test: public URL works; unrelated services not reachable
- [ ] Disable plan: clear `CLOUDFLARE_TUNNEL_TOKEN`, redeploy, confirm container gone

## Disable

```bash
# .env
CLOUDFLARE_TUNNEL_TOKEN=
make deploy
```

## Incident

If tunnel exposes wrong backend: clear token + deploy immediately; rotate tunnel token in Cloudflare dashboard.
