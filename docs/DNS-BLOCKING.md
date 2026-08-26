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

Profile: `ADGUARD_FILTER_PROFILE=balanced` (default, TIF Medium) or `aggressive` (TIF Full + Fake; more RAM). Repo default stays `balanced`. Live Pi can use `aggressive`.

HaGeZi **TIF** (threat intel) ≠ **Multi Ultimate** (ad list). TIF levels: Mini / Medium / Full. Multi Ultimate replaces Pro++ and breaks META/Xbox — not used. Do not stack TIF Full + TIF Medium.

1. **HaGeZi Pro++** — primary ad/tracker list (OISD and others already included)
2. **HaGeZi TIF Medium** (balanced) or **TIF Full** (`adblock/tif.txt`, aggressive; AGH ≥2GB RAM) — malware/phishing. `tif.full.txt` yok; jsDelivr o isimde 403 verir.
3. **HaGeZi DoH/DoT Bypass** — known encrypted-DNS hosts
4. **AdGuard DNS Popup Hosts** — popup hosts
5. **Apple / Windows / Samsung tracker** — device telemetry
6. **HaGeZi Smart TV** + **native.lgwebos** — CTV / LG webOS ad domains
7. **AWAvenue Ads Rule** — Android advertising SDKs (DNS-level; not the AdGuard browser Mobile Ads filter)
8. **User rules** — `config/adguard/user-rules.txt` (Google Ads, mobile SDKs, TR trackers, `$important`)

OISD Big and AdGuard DNS filter (`filter_1`) omitted: duplicate Pro++; waste Pi RAM.
AdGuard browser Mobile Ads (`filters.adtidy.org/.../11.txt`) is CSS/path — skip for AdGuard Home.

Auto-heal: `ADGUARD_AUTO_HEAL=true` (health-check drift → `ensure-adguard-blocking.sh --fix-light`).
Bypass check: `ADGUARD_BYPASS_CHECK=strict` on `make diagnose-dns` (LAN clients must appear in query log).
Custom rules: copy `config/adguard/user-rules.local.txt.example` → `user-rules.local.txt` on the Pi.
Daily filter refresh: `pi-gateway-adguard-filters.timer` (~04:15).
One-shot tune from Mac: `make adguard-tune`.

Migration: `HAGEZI_TIF_FILTER_URL` removed — use `ADGUARD_FILTER_PROFILE` + `config/adguard/filter-lists.json`.

## Modem / router DNS (kritik)

Modem panelinde DNS ayari **tek basina tum cihazlari otomatik Pi'ye baglamaz**.

| Dogru | Yanlis |
|-------|--------|
| LAN / DHCP / Yerel ag DNS = `<PI_STATIC_IP>` | WAN / Internet DNS = Pi IP |
| Ikincil DNS **bos** | DNS2 = 8.8.8.8 veya 1.1.1.1 |
| DHCP lease yenileme (cihaz reboot) | Sadece modem kaydet, cihazlara dokunma |

**Hizli rollout (telefon reboot yok):** Modem LAN Grubu → lease suresi **5 dk (300s)** → Uygula → modem **ac/kapa**. Cihazlar 5–15 dk icinde kendisi yeniler. Izlem: `make rollout-dns-wait`. Is bitince lease'i **3600** veya **86400**'e al (modem kalabalik yenileme yapmasin).

**IPv6 DNS (kapatma yok):** Pi sabit ULA (`PI_IPV6_ULA`, ornek `fd7b:7069:6777::53`). ZTE H3600P LAN menude IPv6 DNS UI yok; modem RDNSS sik `fe80::1`. Cozum: `ensure-ipv6-ula.sh` + `setup-rdnss-ra.sh` (radvd, `AdvDefaultLifetime 0` — default route modemde kalir, ek RDNSS=ULA). GUA dinamik — DNS icin kullanma.

**DoH kilidi:** HaGeZi Encrypted DNS Bypass listesi (`adblock/doh.txt`) — bilinen DoH/DoT hostlari engeller. Ozel/unknown DoH host yine kacabilir.

**Modem ikincil DNS:** Bazı ZTE modemler DNS2 boş olsa bile DHCP OFFER'a kendi IP'sini ekler. Dış DNS (1.1.1.1) değildir; Pi ayaktayken kullanılmaz. Pi düşünce fallback bypass riski kalır — tam kilit için modem Force DNS veya `adguard-dhcp`.

**Force DNS (modem NAT 53):** Hardcoded `8.8.8.8` (LG TV vb.) Pi'ye uğramaz — Pi LAN gateway değil. Intercept **modemde**: Force DNS / DNS hijack / NAT 53 → `PI_STATIC_IP`. Menü adı modele göre değişir.

| Yap | Yapma |
|-----|-------|
| Modem LAN DHCP DNS1 = Pi, DNS2 boş | WAN / Internet DNS = Pi IP |
| Modem Force DNS → Pi (varsa) | Pi'de `iptables REDIRECT :53` — LAN trafiği Pi'ye gelmez, işe yaramaz |
| Pi UFW: :53 yalnız LAN (`setup-firewall.sh`, `deny routed`) | Pi WAN :53'ü Unbound çıkışı için kapatmak — recursive DNS ölür |

**Kontrol:** `make audit-dns` — ARP'taki her cihaz query log'da görünmeli. Yoksa liste değil, bypass (eski lease, Private DNS, iCloud Relay, IPv6 RDNSS).

### Neden bazi cihazlar bypass eder?

1. **Eski DHCP lease** — modem DNS degisti ama telefon/TV eski DNS'i tutuyor
2. **Ikincil DNS** — modem veya cihaz 8.8.8.8'e fallback
3. **Android Ozel DNS** (Private DNS) — Settings → Network → Private DNS → Off
4. **iOS** — iCloud Private Relay / Limit IP Tracking kapali
5. **IPv6 RDNSS** — modem IPv6 DNS farkli sunucu veriyor (modemde IPv6 DNS = Pi veya IPv6 kapat)
6. **Smart TV / konsol** — ag ayarlarinda DNS manuel = Pi IP

### Zorunlu kapsam (tum cihazlar)

`NETWORK_MODE=adguard-dhcp` — Pi DHCP dagitir, her lease Pi DNS alir. Modem DHCP kapatilir. Bkz. `docs/ADGUARD-DHCP.md` (planli bakim penceresi).

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
