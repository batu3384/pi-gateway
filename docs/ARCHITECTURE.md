# Pi Gateway Architecture

Production-grade single-node home dev/DNS server for Raspberry Pi 4B.

## Design goals

- Zero manual config on AdGuard/Unbound after deploy (IaC rendered configs)
- Automatic network discovery and static IP assignment
- Self-healing containers (`recover-stack.sh` + healthchecks)
- Independent DNS health monitoring (systemd timer, not dependent on Gatus)
- Hybrid storage: SD boot + root; USB SSD for application data (`/mnt/ssd`) and optional Docker `data-root`
- Kernel network optimization: TCP BBR + `fq` qdisc, ARP flux protection, and automatic `eth0`↔`wlan0` failover
- Host firewall (UFW) + SSH brute-force protection (CrowdSec)
- TLS on by default; offsite backup SLA (`make backup-pull`)
- Optional AdGuard DHCP — **not on ZTE H3600P** (relay swallows DISCOVER)

## Compose tiers

| Tier | Profile / always-on | Role |
|------|---------------------|------|
| **dns-core** | `unbound`, `adguard` (always) | LAN DNS — keep up even when SSD degraded (+ host DoT `:53` fallback) |
| **panels** | `caddy`, `glance`, `gateway-state`, `gatus`, `dozzle` | `*.home` UI via Caddy+TLS (`docker-socket-proxy` isolates Docker API) |
| **monitoring** | `victoriametrics`, `grafana`, `node-exporter` | Low-RAM metrics store (`128MB` cap) + dashboards |
| **security & lan** | `netalert`, `crowdsec` | LAN ARP/client inventory + SSH/service ban engine (`n8n` retired/off by default) |
| **edge** | `cloudflare` (token) | Optional public edge |

Feature flags: `ENABLE_*` in `.env` → compose profiles (`scripts/lib/compose-profiles.sh`).

## Decisions (ADR)

See [docs/adr/](adr/README.md). Script map: [docs/SCRIPTS.md](SCRIPTS.md).

## Traffic flow

```
Client (DHCP from modem .1)
  DNS1 = Pi .50           DNS2 = .1 (ZTE inject, panel yok sayilir)
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

Owner telefon/Mac (Tailscale, Override):
  DNS --> Pi 100.x:53 (UFW tailscale0) --> ayni AdGuard
  Panel --> Pi 100.x:80/443 -> Tailscale Serve / DNAT -> 127.0.0.1:8088 (Caddy loopback; LAN :80/:443 Basic Auth)
```

Pi **LAN gateway değil.** Aynı L2’de `192.168.1.1:53` Pi’den geçmez. `iptables REDIRECT` / “Pi’yi GW yap” DNS2’yi kesmez (on-link). Yeni kutu veya cihaz DNS yoksa **tavan bu.**

## Reliability evidence

- Filter apply: source preflight → AdGuard reconcile → refresh/status/regression. Son
  başarılı apply `last_success_at` ile korunur; API/network failure eski çalışan
  filtreleri bırakır, kısmi membership/user-rule değişikliğinde rollback sonucu
  state ve metric olarak yazılır.
- Coverage: DHCP offer, fresh modem inventory, ARP ve AdGuard query log ayrı kanıt
  kaynaklarıdır. Inventory disabled iken stale dosya hata sebebi değildir; enabled/
  required stale durum `UNKNOWN`’dır. DHCP modem `.1` secondary ve IPv6 RDNSS pozitif
  lifetime `WARN` olarak kalır.
- Observability: NetAlertX `netalert_db_readable` ile okunamayan SQLite’ı sıfır
  online cihazdan ayırır. Video probe son query penceresini ve küçük median DNS
  örneklerini kullanır; ICMP RTT HTTPS/video buffer kanıtı sayılmaz.

## Mevcut donanım tavanı (kutu yok, elle yok)

| Karar | Neden |
|-------|--------|
| `NETWORK_MODE=router-dns` | Ev IP yaşar. `adguard-dhcp` bu ZTE’de ölçüldü, öldü. |
| Modem DHCP + DNS1=Pi | Tek otomatik dağıtım. DNS2=.1 firmware. |
| WAN dest:53 drop + Unbound DoT | Public resolver :53 kapanır; Pi :853 ile çıkar. |
| Pi forwarding kapalı | SPOF + on-link `.1:53` hâlâ açık = kazanç yok, kesinti var. |
| Mac `make mac-dns` | Tek istemci kilidi (LAN IP). Telefon/TV/IoT DHCP DNS2. |
| Tailscale global NS (`100.x`) | Owner cihaz ev dışında da AdGuard. TV/IoT kapsamaz. |

Tam ev kilidi = başka L2 (OpenWrt) veya cihaz DNS. İkisi de bu hedefte yok. Mimari **availability-first, block best-effort.**

## Components

| Layer | Component | Role |
|-------|-----------|------|
| DNS filter | AdGuard Home | Block ads/trackers, local rewrites |
| DNS resolver | Unbound (klutchell) | DoT forward (Cloudflare Security `1.1.1.2`/`1.0.0.2` + Quad9 `:853`); not recursive. DNSSEC validator (AD + `dnssec-failed.org` SERVFAIL in diagnose) |
| Proxy | Caddy | `gateway.home`, `dns.home`, `status.home`, `grafana.home`, `logs.home`, `devices.home` (Tailscale vhosts bound strictly to `127.0.0.1:8088`) |
| Dashboard | Glance + `gateway-state` | Lightweight dashboard + public `/var/lib/pi-gateway/public/state.json` widget (`modem-inventory.json` isolated) |
| Logs | Dozzle | Live Docker container logs (via isolated `socket_proxy` internal network + `docker-socket-proxy`) |
| Status & Metrics | Gatus + VictoriaMetrics + Grafana + systemd health timer | Uptime, SLO heartbeats, time-series metrics & DNS layer checks |
| Network inventory | NetAlertX | LAN device discovery (`devices.home`), AdGuard client name import |
| Assistant | Hermes Telegram Gateway + `notify.sh` | Conversational ops (`/menu`, `/dns`, `/ssd`, `/backup`, `/recover` + `/recover onay` single-message `--stdout`) + state-transition alerts |
| Recovery | recover-stack.sh | Restart unhealthy / degraded stack |
| Security | UFW + CrowdSec | LAN-scoped admin ports, SSH/DoT `:853` & `:22000` immediate `REJECT` (no Android timeout / kernel log storm), CrowdSec JSON-synced UFW bans |
| Host | journald persistent cap (`99-pi-gateway-persistent.conf`), sysctl BBR+`fq`, NM failover | SD longevity, TCP/UDP performance, NIC redundancy |
| Remote | Tailscale + Raspberry Pi Connect | Remote panels, owner DNS to AdGuard `:53`, desktop screen access |
| Storage | `/mnt/ssd/pi-gateway-data` (symlink `~/pi-gateway/data`) | AdGuard, Gatus, VictoriaMetrics, Grafana, NetAlertX, Restic backups |

## Phased rollout

| Phase | Status | Items |
|-------|--------|-------|
| 0 Foundation | Done | Docker, SSD data disk, UFW, CrowdSec, Tailscale hook |
| 1 DNS & Panels | Done | Unbound, AdGuard, Glance, Gatus, Caddy, Dozzle |
| 2 Backup | Done | Restic (timer + Mac pull + drill); Forgejo/Syncthing removed |
| 3 Monitoring & Edge | Done | VictoriaMetrics + Grafana + `node-exporter`; `n8n` retired (`ENABLE_N8N=false`) |
| 4 Network & Assistant | Done | NetAlertX (`devices.home`), Hermes Telegram Gateway, low-noise `notify.sh` |

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
  -> render-config.sh (AdGuard yaml, Caddy, dhcpcd, Glance, Gatus)
  -> validate.sh (compose + config checks)
  -> deploy.sh (rsync + bootstrap + docker compose + smoke test)
```

## Hybrid storage layout

```
SD (mmcblk):  /           OS root
              /var/lib/containerd (containerd snapshotter)
USB SSD:      /mnt/ssd/
                docker/            <- ENABLE_DOCKER_SSD=true (opt-in)
                pi-gateway-data/   <- ~/pi-gateway/data symlink
                  adguard/work/
                  gatus/
                  victoriametrics/
                  grafana/
                  netalertx/
                  backups/restic/
```

Symlink: `~/pi-gateway/data` → `/mnt/ssd/pi-gateway-data`

Docker images default to SD (`/var/lib/docker`). Set `ENABLE_DOCKER_SSD=true` to move `data-root` to `/mnt/ssd/docker` (frees SD space; more USB I/O on JMicron). On SSD loss, `setup-docker-fallback.sh` reverts Docker to SD; when SSD returns, `setup-docker-ssd.sh` runs from `ssd-hotplug-handler.sh` and `recover-readonly-root.sh`.

Experimental alternative: `ssd-root` — `docs/SSD-ROOT.md`

## Future HA (optional)

Second Pi + Keepalived VIP + adguardhome-sync (not in v1 single-node scope).
