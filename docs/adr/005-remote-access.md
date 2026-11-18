# ADR-005: Remote access

## Status

Accepted

## Context

Need admin from outside home without opening WAN ports on the router. Owner phones leave home Wi-Fi; LAN AdGuard does not follow them unless DNS uses the same tunnel.

## Decision

- **Primary**: Tailscale on host. UFW `tailscale0`: `22/80/443` TCP (Caddy/SSH) and `:53` UDP+TCP (AdGuard). Panels: `https://<panel>.home` via Global DNS + subnet route, or `http://100.x:PORT/` when `TS_PANEL_DIRECT_PORTS=true`.
- **DNS (owner devices)**: Tailscale **global nameserver** = Pi Tailscale IPv4, then Override DNS. Split DNS `home` stays. Pi `--accept-dns=false`. Proof `dig @100.x` from a **client**, not from the Pi. No second global NS. Nameserver is not the LAN IP.
- **Optional**: Cloudflare Tunnel when `CLOUDFLARE_TUNNEL_TOKEN` set — public edge. Must restrict hostnames; prefer HTTPS; treat as increased attack surface.
- Do not expose admin / panel ports on WAN.

## Consequences

- Tailscale ACL owner in `.env` (not committed). ACL `src` includes `group:owners` so untagged phones work; Pi must be `tag:pi-gateway`.
- Override before UFW/ACL `:53` = no DNS on Tailscale-connected phones.
- Android Private DNS / iCloud Relay / Chrome Secure DNS bypass Tailscale DNS.
- TV/IoT without Tailscale stay on DHCP (ZTE DNS2 leak unchanged).
- Tunnel misconfig can publish admin UI — follow `docs/CLOUDFLARE-TUNNEL.md` checklist before deploy.
