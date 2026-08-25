# ADR-005: Remote access

## Status

Accepted

## Context

Need admin from outside home without opening WAN ports on the router.

## Decision

- **Primary**: Tailscale on host; UFW allows `tailscale0` for `22/80/443`; MagicDNS / Serve for panels.
- **Optional**: Cloudflare Tunnel when `CLOUDFLARE_TUNNEL_TOKEN` set — public edge. Must restrict hostnames; prefer HTTPS; treat as increased attack surface.
- Do not expose n8n / panel ports on WAN.

## Consequences

- Tailscale ACL owner in `.env` (not committed).
- Tunnel misconfig can publish admin UI — follow `docs/CLOUDFLARE-TUNNEL.md` checklist before deploy.
