# ADR-002: DNS modes

## Status

Accepted

## Context

Home LAN needs ad-blocking DNS without breaking every client install. Two ops models exist.

## Decision

- Default `NETWORK_MODE=router-dns`: router DHCP unchanged; set router DNS to Pi once. AdGuard+Unbound on Pi.
- Optional `adguard-dhcp`: AdGuard serves DHCP+DNS (router DHCP off). Full automation, higher blast radius.
- Single-node SPOF accepted for v1; HA (2nd Pi + keepalived) is future — `docs/ARCHITECTURE.md`.

## Consequences

- router-dns: one router click; Mac may need DHCP renew.
- adguard-dhcp: Pi down = no DHCP until failover plan.
- Secondary DNS on router may bypass AdGuard (document for users).
