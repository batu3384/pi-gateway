# ADR-003: Security layers

## Status

Accepted

## Context

LAN is partially trusted (guest WiFi, IoT). Admin panels and DNS centralize on one Pi.

## Decision

1. **TLS on by default** (`ENABLE_TLS=true`). Escape: `WEAK_TLS_OK=yes` + `ENABLE_TLS=false`.
2. **UFW** `caddy-only`: admin UIs via Caddy `:80/:443` only; services bind `127.0.0.1`.
3. **CrowdSec** SSH brute-force (UFW sync / bouncer). No fail2ban.
4. **Remote**: Tailscale preferred; Cloudflare Tunnel opt-in with explicit hostname allowlist (`docs/CLOUDFLARE-TUNNEL.md`).
5. **Images pinned** in compose (no `:latest` on critical path); Dependabot weekly.

## Consequences

- First install needs `make tls-certs` before validate/deploy.
- NetAlertX listens `172.17.0.1` (docker0; Caddy `host.docker.internal` proxies `devices.home`).
- HTTP-only LAN is explicit risk acceptance via `WEAK_TLS_OK`.
