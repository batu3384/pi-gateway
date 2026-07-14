# Pi Gateway Architecture

Production-grade single-node home dev/DNS server for Raspberry Pi 4B.

## Design goals

- Zero manual config on AdGuard/Unbound after deploy (IaC rendered configs)
- Automatic network discovery and static IP assignment
- Self-healing containers (autoheal + healthchecks)
- Independent DNS health monitoring (systemd timer, not dependent on Uptime Kuma)
- Hybrid storage: SD boot + USB SSD data (`/mnt/ssd`)
- Host firewall (UFW) + SSH brute-force protection (fail2ban)
- Optional full automation via AdGuard DHCP mode

## Traffic flow

```
Client DNS query
       |
       v
 AdGuard Home (:53, host network)
   | filter blocklists
   v
 Unbound (:5335, recursive)
   | root DNS resolution
   v
 Internet
```

## Components

| Layer | Component | Role |
|-------|-----------|------|
| DNS filter | AdGuard Home | Block ads/trackers, local rewrites |
| DNS resolver | Unbound (klutchell) | Recursive DNS, privacy |
| Proxy | Caddy | gateway.home, dns.home, status.home |
| Dashboard | Homepage | Service links |
| Logs | Dozzle | Live Docker container logs |
| Monitoring | Uptime Kuma + systemd health timer | Uptime + DNS layer checks |
| Recovery | autoheal | Restart unhealthy containers |
| Security | UFW + fail2ban | LAN-scoped admin ports, SSH protection |
| Host | log2ram, sysctl tuning, watchdog | SD longevity, UDP performance |
| Remote | Tailscale (host) | Secure admin from anywhere |
| Storage | `/mnt/ssd/pi-gateway-data` | AdGuard, Kuma, future Forgejo/Syncthing |

## Phased rollout

| Phase | Status | Items |
|-------|--------|-------|
| 0 Foundation | Done | Docker, SSD data disk, UFW, fail2ban, Tailscale hook |
| 1 DNS stack | Done | Unbound, AdGuard, Homepage, Uptime Kuma, Caddy, Dozzle |
| 2 Dev & sync | Done | Forgejo, Syncthing, Restic (timer) |
| 3 Advanced | Done | CrowdSec, Redis, n8n; Cloudflare Tunnel (token ile) |

## Network modes

### router-dns (default)
- Pi gets static IP via router IP reservation + dhcpcd drop-in
- Router DHCP unchanged; set router DNS to Pi static IP once
- Mac/PC may need manual DNS or DHCP renew to use Pi

### adguard-dhcp (full automation)
- Disable router DHCP
- AdGuard serves DHCP + DNS
- All clients automatically use Pi DNS

## Automation pipeline

```
Mac: make install
  -> discover-remote.sh (Pi network scan)
  -> render-config.sh (AdGuard yaml, Caddy, dhcpcd, homepage)
  -> validate.sh (compose + config checks)
  -> deploy.sh (rsync + bootstrap + docker compose + smoke test)
```

## Hybrid storage layout

```
/mnt/ssd/pi-gateway-data/
  adguard/work/
  uptime-kuma/
  forgejo/      (Faz 2)
  syncthing/    (Faz 2)
  restic/       (Faz 2)
  projects/     (Faz 2)
  backups/
```

Symlink: `~/pi-gateway/data` -> `/mnt/ssd/pi-gateway-data`

## Future HA (optional)

Second Pi + Keepalived VIP + adguardhome-sync (not in v1 single-node scope).
