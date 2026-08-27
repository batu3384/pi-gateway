# DNS ad blocking — limits and stack

## Why does phone AdGuard block more?

| Layer | Phone AdGuard | Pi AdGuard Home |
|-------|---------------|-----------------|
| DNS host blocking | Yes | Yes (this project) |
| HTTPS content (path/query) | Yes (local VPN/proxy) | **No** |
| CSS element hiding | Yes | **No** |
| Scriptlet / JS injection | Yes | **No** |

Result: Ads served from the same domain (YouTube `googlevideo.com`, some in-app ads, in-page iframe paths) cannot be blocked by DNS alone. This is normal; it is a DNS-only architecture limit.

## Current DNS stack

Profile: `ADGUARD_FILTER_PROFILE=balanced` (default, TIF Medium) or `aggressive` (TIF Full + Fake + CNAME original; more RAM). Repo default stays `balanced`. Live Pi can use `aggressive`.

HaGeZi **TIF** (threat intel) ≠ **Multi Ultimate** (ad list). TIF levels: Mini / Medium / Full. Multi Ultimate replaces Pro++ and breaks META/Xbox — not used. Do not stack TIF Full + TIF Medium.

1. **HaGeZi Pro++** — primary ad/tracker list (OISD and others already included)
2. **HaGeZi TIF Medium** (balanced) or **TIF Full** (`adblock/tif.txt`, aggressive; AGH ≥2GB RAM) — malware/phishing. `tif.full.txt` yok; jsDelivr o isimde 403 verir.
3. **HaGeZi DoH/DoT Bypass** — known encrypted-DNS hosts
4. **AdGuard DNS Popup Hosts** — popup hosts
5. **Apple / Windows / Samsung tracker** — device telemetry
6. **HaGeZi Smart TV** + **native.lgwebos** — CTV / LG webOS ad domains
7. **AWAvenue Ads Rule** — Android advertising SDKs (DNS-level; not the AdGuard browser Mobile Ads filter)
8. **User rules** — `config/adguard/user-rules.txt` (Google Ads, mobile SDKs, TR trackers, `$important`)
9. **AdGuard CNAME original trackers** (aggressive only) — `combined_original_trackers.txt`. AGH already follows CNAME in responses; this list is the *original* tracker hostnames AdGuard recommends for CNAME-capable resolvers. Do **not** add `combined_disguised_trackers.txt` (first-party alias names; microsite/clickthrough FP). ~4KB.

OISD Big and AdGuard DNS filter (`filter_1`) omitted: duplicate Pro++; waste Pi RAM.
AdGuard browser Mobile Ads (`filters.adtidy.org/.../11.txt`) is CSS/path — skip for AdGuard Home.

Auto-heal: `ADGUARD_AUTO_HEAL=true` (health-check drift → `ensure-adguard-blocking.sh --fix-light`).
Bypass check: `ADGUARD_BYPASS_CHECK=strict` on `make diagnose-dns` (LAN clients must appear in query log).
Custom rules: copy `config/adguard/user-rules.local.txt.example` → `user-rules.local.txt` on the Pi.
Daily filter refresh: `pi-gateway-adguard-filters.timer` (~04:15).
One-shot tune from Mac: `make adguard-tune` (post-deploy yok). Unbound `--force-recreate` yalnız `unbound.conf` container start'tan yeni ise — filtre-only DNS deliği yok.

**Grafana:** `export-adguard-metrics.sh` (health timer, textfile) → blocked ratio + per-list `rules_count` / `last_updated` age. A silent 403 on one list shows as that series going stale, not only `ADGUARD_MIN_FILTER_RULES`.

**DNSSEC:** Unbound default validator. Proof (not assumption): `diagnose-dns-bypass.sh` / smoke — Unbound `:5335` AD flag on `cloudflare.com`; `dnssec-failed.org` SERVFAIL (`+time=8`, first miss can exceed 3s). Health timer checks AD only (no flaky third-party bogus domain every 2 min). AGH may copy AD to clients; contract is Unbound.

Migration: `HAGEZI_TIF_FILTER_URL` removed — use `ADGUARD_FILTER_PROFILE` + `config/adguard/filter-lists.json`.

## Modem / router DNS (kritik)

Modem panelinde DNS ayari **tek basina tum cihazlari otomatik Pi'ye baglamaz**.

| Dogru | Yanlis |
|-------|--------|
| LAN / DHCP / Yerel ag DNS = `<PI_STATIC_IP>` | WAN / Internet DNS = Pi IP |
| Ikincil DNS **bos** | DNS2 = 8.8.8.8 veya 1.1.1.1 |
| DHCP lease yenileme (cihaz reboot) | Sadece modem kaydet, cihazlara dokunma |

**Hizli rollout (telefon reboot yok):** Modem LAN Grubu → lease suresi **5 dk (300s)** → Uygula → modem **ac/kapa**. Cihazlar 5–15 dk icinde kendisi yeniler. Izlem: `make rollout-dns-wait`. Is bitince lease'i **3600** veya **86400**'e al (modem kalabalik yenileme yapmasin).

**IPv6 DNS:** Pi sabit ULA (`PI_IPV6_ULA`). ZTE LAN IPv6 DNS UI yok. `setup-rdnss-ra.sh`: ULA RDNSS + modem LL lifetime 0, RA 3–4s (modem RA `fe80::1` 900s last-RA). Default route modemde. `dig @fe80::1` daemon hâlâ cevaplar. GUA dinamik — DNS icin kullanma.

**DoH kilidi:** HaGeZi Encrypted DNS Bypass listesi (`adblock/doh.txt`) — bilinen DoH/DoT hostlari engeller. Ozel/unknown DoH host yine kacabilir.

**Modem ikincil DNS:** ZTE H3600P (Superonline) DNS2 panelde boş/`0.0.0.0` veya **Pi** olsa bile DHCP OFFER'a gateway (`.1`) ekler. Panel DNS2 kabloyu değiştirmez. `.1` modem **INPUT** resolver reklam engellemez (WAN dest:53 ve LAN-ingress dest `.1:53` FORWARD; modem kendi `:53` cevaplar). Canlı: `dig @192.168.1.1 doubleclick.net` gerçek IP. Bu ZTE'de DHCP relay LAN DISCOVER yutuyor — `adguard-dhcp` ev IP keser; kilit = modem DHCP açık + DNS1=Pi + `make mac-dns` (yalnız LAN). IPv6: aşağıdaki RDNSS lifetime 0.

**H3600P Force DNS yok.** 78 menüde NAT 53 / DNS hijack yok. Yakın çare: **WAN → Güvenlik → Filtre Kriterleri → IP Filtresi** — Hedef=Düşür, dest port 53, proto 257, `IPVersion=-1`. Dest IP **boş** = tüm public `:53` (1.0.0.1, 9.9.9.9, IPv6 resolver). CHAIN1 WAN; LAN→Pi `:53` düşmez. **Sıra:** Unbound DoT (`forward-tls-upstream`, Quad9/CF `:853`) **önce** — recursive UDP 53 drop Unbound'u öldürür. Custom conf: `port: 5335` + `forward-zone` (klutchell `tls-cert-bundle` imajda; default port 53). Deploy `canary-compose-update.sh` Unbound'u `--force-recreate` eder; health `StartedAt` vs conf mtime stale ise fail (restart AdGuard'ı düşürür). Unbound compose healthcheck **kapalı** (`unbound-host` recursive `:53` WAN drop ile forever unhealthy → auto-recover döngüsü). AdGuard `depends_on: service_started`. Host `dig :5335` gerçek probe. 3 slot tavan; boş dest tek kural yeter. `/32` yedek olabilir. Yeni Madde spam'i mevcut kuralı ezer — mevcut instance düzenle. DROP ≠ redirect.

**Kablolu + WiFi:** OS ethernet'i tercih eder. O NIC'te DNS=8.8.8.8/1.1.1.1 ise WAN drop = "LAN internet yok, kabloyu çekince WiFi gelir". Mac: `make mac-dns` (Ethernet+Wi-Fi → Pi [+ULA]; public yedek yok). Wi-Fi DNS boşsa RDNSS `fe80::1` önce — internet var, reklam modemden kaçar.

| Yap | Yapma |
|-----|-------|
| Modem LAN DHCP DNS1 = Pi, DNS2 boş (OFFER yine `.1` basabilir) | WAN / Internet DNS = Pi IP |
| H3600P: dest boş `:53` Düşür (Unbound DoT ayakta) | Pi'de `iptables REDIRECT :53` — LAN trafiği Pi'ye gelmez, işe yaramaz |
| Pi UFW: :53 yalnız LAN (`setup-firewall.sh`, `deny routed`) | Unbound DoT yokken WAN `:53` drop — recursive ölür |
| LAN Grubu Apply yalnız DNS/lease — SSID checkbox'a dokunma | Misafir SSID (`Misafir_*`) açık bırakmak |

**Kontrol:** `make audit-dns` — ARP'taki her cihaz query log'da görünmeli. Yoksa liste değil, bypass (eski lease, Private DNS, iCloud Relay, IPv6 RDNSS).

### Neden bazi cihazlar bypass eder?

1. **Eski DHCP lease** — modem DNS degisti ama telefon/TV eski DNS'i tutuyor
2. **Ikincil DNS** — DHCP `.1` (ZTE) veya cihaz hardcoded DNS (dest boş `:53` drop yoksa) / DoH / IPv6 RDNSS
3. **Android Ozel DNS** (Private DNS) — Settings → Network → Private DNS → Off
4. **iOS** — iCloud Private Relay / Limit IP Tracking kapali
5. **IPv6 RDNSS** — modem IPv6 DNS farkli sunucu veriyor (modemde IPv6 DNS = Pi veya IPv6 kapat)
6. **Smart TV / konsol** — ag ayarlarinda DNS manuel = Pi IP

### Zorunlu kapsam (tum cihazlar)

Baska modemlerde: `NETWORK_MODE=adguard-dhcp` (modem DHCP kapat). **ZTE H3600P:** relay DISCOVER yutuyor — kullanma; modem DHCP + DNS1=Pi + istemci `make mac-dns`. Bkz. `docs/ADGUARD-DHCP.md`.

## Browser / YouTube / SSAI

DNS kills third-party ad **domains** (game/app SDKs, `doubleclick.net`). Same-origin / SSAI ads stay: YouTube `googlevideo.com`, Instagram in-feed, Netflix/Prime baked-in ads. iSponsorBlockTV is out of scope (TV pairing). Device-side only if you choose to:

- Safari: AdGuard for Safari / uBlock Origin Lite
- Chrome/Firefox: uBlock Origin
- YouTube: browser extension or SponsorBlock (DNS cannot fix this)

## Update

```bash
ssh "$PI_USER@$PI_STATIC_IP" 'REMOTE_DIR=~/pi-gateway bash ~/pi-gateway/scripts/pi/apply-adguard-dns.sh'
ssh "$PI_USER@$PI_STATIC_IP" 'REMOTE_DIR=~/pi-gateway bash ~/pi-gateway/scripts/pi/apply-adguard-filters.sh'
```

After deploy, `post-deploy` runs automatically: `wait-adguard-dns` → `apply-adguard-dns` → `apply-adguard-filters`.

## Boot note

After a Pi reboot, DNS port 53 may take ~30–90 seconds to open (filter loading). If the Mac uses the Pi as its only DNS server, wait for the Pi to be ready first.
