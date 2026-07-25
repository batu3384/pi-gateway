# Pi Gateway Architecture

Production-grade single-node home dev/DNS server for Raspberry Pi 4B.

## Design goals

- Zero manual config on AdGuard/Unbound after deploy (IaC rendered configs)
- Automatic network discovery and static IP assignment
- Self-healing containers (autoheal + healthchecks)
- Independent DNS health monitoring (systemd timer, not dependent on Uptime Kuma)
- Hybrid storage: SD boot + root; USB SSD for application data (`/mnt/ssd`)
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
| Network inventory | NetAlertX | LAN device discovery, new/offline alerts |
| Recovery | autoheal | Restart unhealthy containers |
| Security | UFW + fail2ban | LAN-scoped admin ports, SSH protection |
| Host | log2ram, sysctl tuning, watchdog | SD longevity, UDP performance |
| Remote | Tailscale (host) | Secure admin from anywhere |
| Storage | `/mnt/ssd/pi-gateway-data` (symlink `~/pi-gateway/data`) | AdGuard, Kuma, Forgejo, Syncthing, backups |

## Phased rollout

| Phase | Status | Items |
|-------|--------|-------|
| 0 Foundation | Done | Docker, SSD data disk, UFW, fail2ban, Tailscale hook |
| 1 DNS stack | Done | Unbound, AdGuard, Homepage, Uptime Kuma, Caddy, Dozzle |
| 2 Dev & sync | Done | Forgejo, Syncthing, Restic (timer) |
| 3 Advanced | Done | CrowdSec, Redis, n8n; Cloudflare Tunnel (with token) |
| 4 Network visibility | Done | NetAlertX — `devices.home`, n8n webhook alerts |

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
SD (mmcblk):  /           OS root, /var/lib/docker (default)
USB SSD:      /mnt/ssd/
                pi-gateway-data/   <- ~/pi-gateway/data symlink
                  adguard/work/
                  uptime-kuma/
                  forgejo/
                  syncthing/
                  n8n/
                  netalertx/
                  backups/restic/
                  projects/
```

Symlink: `~/pi-gateway/data` → `/mnt/ssd/pi-gateway-data`

Docker images default to SD (`/var/lib/docker`). If you see I/O issues on JMicron USB SSD, keep `ENABLE_DOCKER_SSD=false` (recommended).

Experimental alternative: `ssd-root` — `docs/SSD-ROOT.md`

## Future HA (optional)

Second Pi + Keepalived VIP + adguardhome-sync (not in v1 single-node scope).
