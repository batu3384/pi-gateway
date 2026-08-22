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

Profile: `ADGUARD_FILTER_PROFILE=balanced` (default) or `aggressive` (TIF full + fake; more RAM).

1. **HaGeZi Pro++** — primary ad/tracker list (OISD and others already included)
2. **HaGeZi TIF Medium** (balanced) or **TIF Full** (aggressive) — malware/phishing
3. **AdGuard DNS Popup Hosts** — popup hosts
4. **Apple / Windows / Samsung tracker** — device telemetry
5. **HaGeZi Smart TV** — CTV / smart TV ad domains
6. **User rules** — `config/adguard/user-rules.txt` (Google Ads, mobile SDKs, TR trackers, `$important`)

OISD Big is intentionally omitted: duplicates Pro++; wastes Pi RAM.

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

**Modem ikincil DNS:** Bazi ZTE modemler DNS2 bos olsa bile DHCP OFFER'a kendi IP'sini ekler. Dis DNS (1.1.1.1) degildir; Pi ayaktayken kullanilmaz. Pi dusunce fallback bypass riski kalir — tam kilit icin modem force-DNS veya `adguard-dhcp`.

**Kontrol:** `make audit-dns` — ARP'taki her cihaz query log'da gorunmeli.

### Neden bazi cihazlar bypass eder?

1. **Eski DHCP lease** — modem DNS degisti ama telefon/TV eski DNS'i tutuyor
2. **Ikincil DNS** — modem veya cihaz 8.8.8.8'e fallback
3. **Android Ozel DNS** (Private DNS) — Settings → Network → Private DNS → Off
4. **iOS** — iCloud Private Relay / Limit IP Tracking kapali
5. **IPv6 RDNSS** — modem IPv6 DNS farkli sunucu veriyor (modemde IPv6 DNS = Pi veya IPv6 kapat)
6. **Smart TV / konsol** — ag ayarlarinda DNS manuel = Pi IP

### Zorunlu kapsam (tum cihazlar)

`NETWORK_MODE=adguard-dhcp` — Pi DHCP dagitir, her lease Pi DNS alir. Modem DHCP kapatilir. Bkz. `docs/ADGUARD-DHCP.md` (planli bakim penceresi).

## Browser / YouTube

If DNS is not enough, add on the device:

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
