# Pi Gateway Architecture

Production-grade single-node home dev/DNS server for Raspberry Pi 4B.

## Design goals

- Zero manual config on AdGuard/Unbound after deploy (IaC rendered configs)
- Automatic network discovery and static IP assignment
- Self-healing containers (`recover-stack.sh` + healthchecks)
- Independent DNS health monitoring (systemd timer, not dependent on Uptime Kuma)
- Hybrid storage: SD boot + root; USB SSD for application data (`/mnt/ssd`)
- Host firewall (UFW) + SSH brute-force protection (CrowdSec)
- TLS on by default; offsite backup SLA (`make backup-pull`)
- Optional AdGuard DHCP — **not on ZTE H3600P** (relay swallows DISCOVER)

## Compose tiers

| Tier | Profile / always-on | Role |
|------|---------------------|------|
| **dns-core** | `unbound`, `adguard` (always) | LAN DNS — keep up even when SSD degraded |
| **panels** | `caddy`, homepage, uptime-kuma, `dozzle` | `*.home` UI via Caddy+TLS |
| **automation** | `n8n`, `netalert`, `crowdsec` | Best-effort apps on SSD data |
| **edge** | `cloudflare` (token) | Optional public edge |

Feature flags: `ENABLE_*` in `.env` → compose profiles (`scripts/lib/compose-profiles.sh`).

## Decisions (ADR)

See [docs/adr/](adr/README.md). Script map: [docs/SCRIPTS.md](SCRIPTS.md).

## Traffic flow

```
Client (DHCP from modem .1)
  DNS1 = Pi .112          DNS2 = .1 (ZTE inject, panel yok sayilir)
  IPv6 RDNSS = fe80::1    (+ Pi ULA RA, last-RA savasi)
       |                      |
       v                      v
 AdGuard :53              Modem INPUT :53  ← ayni L2, Pi gormez
   | blocklists               (reklam kacar)
   v
 Unbound :5335 DoT :853
   | WAN dest:53 drop
   v
 Internet
```

Pi **LAN gateway değil.** Aynı L2’de `192.168.1.1:53` Pi’den geçmez. `iptables REDIRECT` / “Pi’yi GW yap” DNS2’yi kesmez (on-link). Yeni kutu veya cihaz DNS yoksa **tavan bu.**

## Mevcut donanım tavanı (kutu yok, elle yok)

| Karar | Neden |
|-------|--------|
| `NETWORK_MODE=router-dns` | Ev IP yaşar. `adguard-dhcp` bu ZTE’de ölçüldü, öldü. |
| Modem DHCP + DNS1=Pi | Tek otomatik dağıtım. DNS2=.1 firmware. |
| WAN dest:53 drop + Unbound DoT | Public resolver :53 kapanır; Pi :853 ile çıkar. |
| Pi forwarding kapalı | SPOF + on-link `.1:53` hâlâ açık = kazanç yok, kesinti var. |
| Mac `make mac-dns` | Tek istemci kilidi (LAN IP). Telefon/TV/IoT DHCP DNS2. |

Tam ev kilidi = başka L2 (OpenWrt) veya cihaz DNS. İkisi de bu hedefte yok. Mimari **availability-first, block best-effort.**

## Components

| Layer | Component | Role |
|-------|-----------|------|
| DNS filter | AdGuard Home | Block ads/trackers, local rewrites |
| DNS resolver | Unbound (klutchell) | DoT forward (Quad9/CF :853); not recursive. DNSSEC validator (AD + `dnssec-failed.org` SERVFAIL in diagnose) |
| Proxy | Caddy | gateway.home, dns.home, status.home |
| Dashboard | Homepage | Service links |
| Logs | Dozzle | Live Docker container logs |
| Monitoring | Uptime Kuma + systemd health timer | Uptime + DNS layer checks |
| Network inventory | NetAlertX | LAN device discovery, new/offline alerts |
| Recovery | recover-stack.sh | Restart unhealthy / degraded stack |
| Security | UFW + CrowdSec | LAN-scoped admin ports, SSH protection |
| Host | log2ram, sysctl tuning, watchdog | SD longevity, UDP performance |
| Remote | Tailscale (host) | Secure admin from anywhere |
| Storage | `/mnt/ssd/pi-gateway-data` (symlink `~/pi-gateway/data`) | AdGuard, Kuma, n8n, backups |

## Phased rollout

| Phase | Status | Items |
|-------|--------|-------|
| 0 Foundation | Done | Docker, SSD data disk, UFW, CrowdSec, Tailscale hook |
| 1 DNS stack | Done | Unbound, AdGuard, Homepage, Uptime Kuma, Caddy, Dozzle |
| 2 Backup | Done | Restic (timer); Forgejo/Syncthing removed |
| 3 Advanced | Done | CrowdSec, n8n; Cloudflare Tunnel (with token) |
| 4 Network visibility | Done | NetAlertX — `devices.home`, n8n webhook alerts |

## Network modes

### router-dns (default)
- Pi gets static IP via router IP reservation + dhcpcd drop-in
- Set router **DHCP DNS1** to Pi. ZTE still adds DNS2=gateway (unfiltered LAN `:53`)
- Mac: `make mac-dns` (Pi+ULA, yalnız ev LAN IP). Other clients: DHCP renew; DNS2 may bypass
- ZTE relay LAN DISCOVER yutuyor — `adguard-dhcp` ev IP keser. LAN dest `.1:53` drop INPUT resolver’ı kesmez. Pi’yi GW yapmak on-link `.1:53` kesmez. Tavan: [ARCHITECTURE.md](ARCHITECTURE.md) “Mevcut donanım tavanı”. — [DNS-BLOCKING.md](DNS-BLOCKING.md)

### adguard-dhcp (diğer router; ZTE H3600P hayır)
- Disable router DHCP; AdGuard serves DHCP + DNS
- ZTE H3600P: relay LAN DISCOVER yutuyor — ev IP keser. Bu kutuda kullanma. [ADGUARD-DHCP.md](ADGUARD-DHCP.md)

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
SD (mmcblk):  /           OS root
              /var/lib/docker (default; ENABLE_DOCKER_SSD=false)
USB SSD:      /mnt/ssd/
                docker/            <- ENABLE_DOCKER_SSD=true (opt-in)
                pi-gateway-data/   <- ~/pi-gateway/data symlink
                  adguard/work/
                  uptime-kuma/
                  n8n/
                  netalertx/
                  backups/restic/
```

Symlink: `~/pi-gateway/data` → `/mnt/ssd/pi-gateway-data`

Docker images default to SD (`/var/lib/docker`). Set `ENABLE_DOCKER_SSD=true` to move `data-root` to `/mnt/ssd/docker` (frees SD space; more USB I/O on JMicron). On SSD loss, `setup-docker-fallback.sh` reverts Docker to SD; when SSD returns, `setup-docker-ssd.sh` runs from `ssd-hotplug-handler.sh` and `recover-readonly-root.sh`.

Experimental alternative: `ssd-root` — `docs/SSD-ROOT.md`

## Future HA (optional)

Second Pi + Keepalived VIP + adguardhome-sync (not in v1 single-node scope).
