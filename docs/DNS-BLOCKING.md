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

Profile: `ADGUARD_FILTER_PROFILE=balanced` (default, TIF Medium) or `aggressive` (TIF Full + CNAME original; more RAM). Repo default stays `balanced`. Live Pi can use `aggressive`. Fake list **not** stacked — Pro++ already includes it. **AdGuard DNS Popup Hosts** (`filter_59`) **not** stacked — Pro++ already covers popups.

HaGeZi **TIF** (threat intel) ≠ **Multi Ultimate** (ad list). TIF levels: Mini / Medium / Full. Multi Ultimate replaces Pro++ and breaks META/Xbox — not used. Do not stack TIF Full + TIF Medium. TIF Full: apply script WARNs if `MemAvailable` < 400MiB — switch to `balanced` (TIF Medium), do not add more lists.

1. **HaGeZi Pro++** — primary ad/tracker list (OISD, popup hosts, and others already included)
2. **HaGeZi TIF Medium** (balanced) or **TIF Full** (`adblock/tif.txt`, aggressive; AGH ≥2GB RAM) — malware/phishing. `tif.full.txt` yok; jsDelivr o isimde 403 verir.
3. **HaGeZi DoH/DoT Bypass** — known encrypted-DNS hosts
4. **Apple / Windows / Samsung tracker** — device telemetry
5. **Perflyst/Dandelion Smart TV** (`filter_7`) + **native.lgwebos** — CTV / LG webOS. Not HaGeZi Multi.
6. **AWAvenue Ads Rule** — Android advertising SDKs (DNS-level; not the AdGuard browser Mobile Ads filter)
7. **User rules** — `config/adguard/user-rules.txt` (`$important` pins + sniper; `@@` allowlist for WhatsApp / Instagram graph + fallback / ColorOS appconf hosts). Apply compares disk **and** AGH `user_rules` (hash-only skip dropped rules). `set_rules` then `cache_clear`.
8. **AdGuard CNAME original trackers** (aggressive only) — `combined_original_trackers.txt`. AGH already follows CNAME in responses; this list is the *original* tracker hostnames AdGuard recommends for CNAME-capable resolvers. Do **not** add `combined_disguised_trackers.txt` (first-party alias names; microsite/clickthrough FP). ~4KB.

OISD Big and AdGuard DNS filter (`filter_1`) omitted: duplicate Pro++; waste Pi RAM.
AdGuard browser Mobile Ads (`filters.adtidy.org/.../11.txt`) is CSS/path — skip for AdGuard Home. Do **not** add Multi Ultimate / NRD / abused-TLD / TIF-IP-in-DNS.

Kaçan reklam: query log → one `user-rules.txt` sniper line. New mega-list yok.

Auto-heal: `ADGUARD_DNS_AUTO_HEAL=true` (TTL/upstream via `apply-adguard-dns.sh`, cache_clear yok). Filter drift: `ADGUARD_AUTO_HEAL=true` (`apply-adguard-filters.sh` + cache_clear — varsayılan kapalı). Health prefers `REMOTE_DIR/scripts/pi/` (`ensure-adguard-blocking.sh --fix-light`, `apply-adguard-filters.sh`, `apply-adguard-dns.sh`) so systemd `/usr/local/lib` snapshot cannot re-apply a stale hash-only skip. Those three are also in `install-privileged-scripts.sh` as fallback.
Bypass check: `ADGUARD_BYPASS_CHECK=strict` on `make diagnose-dns` (LAN clients must appear in query log).
Custom rules: copy `config/adguard/user-rules.local.txt.example` → `user-rules.local.txt` on the Pi.
Daily filter refresh: `pi-gateway-adguard-filters.timer` (~04:15). Kaynak değişirse
scheduled refresh zorunlu; değişmediyse 304/digest sonucu gereksiz refresh atlanır.
API/network failure `last_success_at` değerini ilerletmez, filter service failure alert
üretir ve başarısız apply sonrası membership/user-rule rollback denenir.
One-shot tune from Mac: `make adguard-tune` (post-deploy yok). Unbound `--force-recreate` yalnız `unbound.conf` container start'tan yeni ise — filtre-only DNS deliği yok.

**Liste governance:** `filter-lists.json` her URL için kategori, minimum/maksimum kural
bütçesi ve maksimum yaş taşır. `apply-adguard-filters.sh` değişiklikten önce HTTPS,
izinli source host, redirect ve bounded content/syntax preflight; sonra her listenin
`enabled`, `rules_count`, `last_updated` ve kritik medya regression setini kontrol eder.
Sonuç `/var/lib/pi-gateway/adguard-filter-state.json` içine yazılır. Başarılı scheduled
apply yaş SLA’sı 26 saattir; liste yaş sınırı 168 saattir. `@latest` kaynakları
upstream tarafından imzalanmadığı için digest/delta guard tam supply-chain garantisi
değildir. `googlevideo.com`, `ytimg.com`, Instagram CDN, WhatsApp medya alan adları
korunur; yeni mega-list eklenmez.

**DNS knobs** (`apply-adguard-dns.sh`, env): `ADGUARD_RATELIMIT=50` (Tailscale burst; düşürme), `ADGUARD_CACHE_SIZE=16777216` (16MiB), `ADGUARD_QUERYLOG_INTERVAL_DAYS=7` + `ADGUARD_STATS_INTERVAL_DAYS=7`. Fresh install template aynı. TLD/IDN blanket block yok (FP). Kaçan reklam: manuel “reklam şimdi” + querylog — otomatik haftalık LLM rapor yok.

**Grafana:** `export-adguard-metrics.sh` (health timer, textfile) → blocked ratio, top clients / blocked domains, per-list `rules_count` / `last_updated` age, filter apply failure, rollback failure ve last verified apply timestamp. `audit-dns-coverage.sh` her health tick’inde `/var/lib/pi-gateway/dns-coverage-state.json` yazar; dashboard `pi_gateway_dns_coverage_percent`, `pi_gateway_dns_coverage_status` (1=OK, 2=WARN, 3=FAIL, 4=UNKNOWN), `pi_gateway_dns_coverage_protocol_unknown` ve IPv6 `pi_gateway_ipv6_rdnss_configured` metriklerini gösterir. Query protocol API’de yoksa status WARN olur; kanıt `600s` aşarsa UNKNOWN olur. A silent 403 on one list shows as that series going stale, not only `ADGUARD_MIN_FILTER_RULES`.

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

**IPv6 DNS:** Pi sabit ULA (`PI_IPV6_ULA`). ZTE LAN IPv6 DNS UI yok. `setup-rdnss-ra.sh`: ULA `/64` on-link prefix (SLAAC kapalı) + RDNSS + modem LL lifetime 0, RA 3–4s (modem RA `fe80::1` 900s last-RA). Default route modemde. Mac: `make mac-dns` ULA erişilemezse yalnız IPv4 Pi yazar (ölü resolver timeout önlenir).

**DoH kilidi:** HaGeZi Encrypted DNS Bypass listesi (`adblock/doh.txt`) — bilinen DoH/DoT hostlari engeller. Ozel/unknown DoH host yine kacabilir.

**Filtre governance:** Her listenin `min_rules`, `max_rules` ve `max_age_hours`
kontrolüne ek olarak profil toplam kural bütçesi vardır. `@latest` kaynakları
ETag/If-Modified-Since ve örnek hash ile preflight edilir; büyük örnek değişimi
ve toplam bütçe aşımı refresh'i durdurur. Başarılı apply sonrası son iyi örnek hash'i
saklanır. Bu, upstream kaynağı imzalamaz; hatalı küçük değişiklikler için query-log
ve regression kontrolleri yine gereklidir. Regression seti `googlevideo.com`,
`ytimg.com`, Instagram CDN, `whatsapp.net`, ColorOS app-config ve `lgappstv.com`
allow; `lgads.tv` block. `videooplayer.xyz` player+reklam aynı host — sniper video kırıyor, yok.

**Modem ikincil DNS:** ZTE H3600P (Superonline) DNS2 panelde boş/`0.0.0.0` veya **Pi** olsa bile DHCP OFFER'a gateway (`.1`) ekler. Panel DNS2 kabloyu değiştirmez. `.1` modem **INPUT** resolver reklam engellemez (WAN dest:53 ve LAN-ingress dest `.1:53` FORWARD; modem kendi `:53` cevaplar). Canlı: `dig @192.168.1.1 doubleclick.net` gerçek IP. Bu ZTE'de DHCP relay LAN DISCOVER yutuyor — `adguard-dhcp` ev IP keser; kilit = modem DHCP açık + DNS1=Pi + `make mac-dns` (yalnız LAN). IPv6: aşağıdaki RDNSS lifetime 0.

**Cihaz envanteri:** H3600P panelindeki DHCP/WLAN adları için
`MODEM_INVENTORY_ENABLED=true` yapın ve `/etc/pi-gateway/modem-inventory.env`
dosyasını root `0600` olarak oluşturun. `pi-gateway-modem-inventory.timer` yalnız
enabled + credential hazırken çalışır ve her 5 dakikada read-only snapshot üretir;
MAC eşleşmesi IP'den önceliklidir.
Snapshot yok/eski ise audit `UNKNOWN`/`STALE` üretir, eski ARP kaydını kesin bypass
saymaz. NetAlertX ve DNS audit aynı `scripts/lib/modem_inventory.py` loader'ını
kullanır; çıktıda `source`, `inventory_confidence`, `privacy_mac` ve
`inventory_last_seen` kanıt alanları bulunur. Coverage yüzdesi stale cihazları
paydadan çıkarır; enabled/required inventory stale ise strict audit'i `UNKNOWN` yapar.
Inventory disabled ise eski snapshot strict unknown sebebi değildir. NetAlertX DB
okunamazsa `netalert_db_readable=0` ayrı metric/UNKNOWN kanıtı üretilir. Elle kontrol:
`make modem-inventory`.

**Modem inventory transport:** `MODEM_URL=https://...` ve doğrulanmış
`MODEM_TLS_CA_FILE` tercih edilir. HTTP fallback script içinde zorlanmaz; yalnız
credential/config üzerinden `MODEM_ALLOW_HTTP=true` ile açıkça etkinleşir ve LAN’da
şifresiz login warning üretir. Inventory sync/login hatası audit’i başarısız yapar;
DHCP ve Pi DNS başarılı diye eksik modem snapshot gizlenmez.

**H3600P Force DNS yok.** 78 menüde NAT 53 / DNS hijack yok. Yakın çare: **WAN → Güvenlik → Filtre Kriterleri → IP Filtresi** — Hedef=Düşür, dest port 53, proto 257, `IPVersion=-1`. Dest IP **boş** = tüm public `:53` (1.0.0.1, 9.9.9.9, IPv6 resolver). CHAIN1 WAN; LAN→Pi `:53` düşmez. **Sıra:** Unbound DoT (`forward-tls-upstream`, Quad9/CF `:853`) **önce** — recursive UDP 53 drop Unbound'u öldürür. Custom conf: `port: 5335` + `forward-zone` (klutchell `tls-cert-bundle` imajda; default port 53). Deploy `canary-compose-update.sh` Unbound'u `--force-recreate` eder; health `StartedAt` vs conf mtime stale ise fail (restart AdGuard'ı düşürür). Unbound compose healthcheck **kapalı** (`unbound-host` recursive `:53` WAN drop ile forever unhealthy → auto-recover döngüsü). AdGuard `depends_on: service_started`. Host `dig :5335` gerçek probe. 3 slot tavan; boş dest tek kural yeter. `/32` yedek olabilir. Yeni Madde spam'i mevcut kuralı ezer — mevcut instance düzenle. DROP ≠ redirect.

**Kablolu + WiFi:** OS ethernet'i tercih eder. O NIC'te DNS=8.8.8.8/1.1.1.1 ise WAN drop = "LAN internet yok, kabloyu çekince WiFi gelir". Mac: `make mac-dns` (Ethernet+Wi-Fi → Pi [+ULA]; public yedek yok). Wi-Fi DNS boşsa RDNSS `fe80::1` önce — internet var, reklam modemden kaçar.

### Tailscale (owner telefon/Mac — ev dışı AdGuard)

Panel tüneli aynı (`http://100.x`). DNS evde DHCP; dışarıda ISP — Tailscale DNS yoksa filtre sıfır. Sıra: UFW `tailscale0` `:53` UDP+TCP → ACL `tag:pi-gateway:53` (`group:owners`) → **Mac/telefon** `dig @100.x` (Pi local `dig` UFW doğrulamaz) → admin **global nameserver = Pi Tailscale IPv4** (LAN IP değil) → Override. İkinci global NS yok. Pi `--accept-dns=false`. Chrome Secure DNS / Android Private DNS / iCloud Relay Tailscale DNS’i deler. TV/IoT Tailscale yok. Ayrıntı: [TAILSCALE.md](TAILSCALE.md).

| Yap | Yapma |
|-----|-------|
| Modem LAN DHCP DNS1 = Pi, DNS2 boş (OFFER yine `.1` basabilir) | WAN / Internet DNS = Pi IP |
| H3600P: dest boş `:53` Düşür (Unbound DoT ayakta) | Pi'de `iptables REDIRECT :53` — LAN trafiği Pi'ye gelmez, işe yaramaz |
| Pi UFW: :53 LAN + `tailscale0` (`setup-firewall.sh`, `deny routed`) | Unbound DoT yokken WAN `:53` drop — recursive ölür |
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

## Video takılmasını DNS'ten ayırma

```bash
VIDEO_TEST_IP=192.168.1.x make diagnose-video
```

Komut cihazı, zaman damgasını, yalnız fresh modem snapshot `band`/`rssi`/`channel` alanlarını;
Pi→cihaz, gateway ve internet packet loss/RTT özetlerini ve cihazın AdGuard
query-log medya alan adlarını son `VIDEO_QUERY_RECENCY_SEC` penceresiyle birlikte çıkarır.
5 GHz ve 2.4 GHz sonuçlarını aynı cihazda ayrı zaman pencerelerinde karşılaştırın. Query-log'da block görünmemesi
tek başına video transport'unun sağlıklı olduğunu kanıtlamaz; DoH/DoT/DoQ ve
Wi-Fi radyo koşulları ayrı kanıttır.
Araç `VIDEO_PROBE_STATUS=OK|WARN|FAIL` üretir: hedef cihaz packet loss'u varsayılan `%20`
veya RTT jitter mdev'i `30 ms` üstünde `WARN`, gateway/WAN packet loss veya Pi kaynaklı
HTTPS probe hatası `FAIL` olur.
HTTPS probe yalnızca Pi→internet kanıtıdır; ZTE ile aynı Layer-2 ağdaki başka cihazın
şifreli CDN akışı Pi üzerinden geçmediği için client video transport'unu doğrudan ölçmez.
Client `ping` 100% + `VIDEO_NEIGH` `REACHABLE|DELAY|PROBE` = ICMP filtresi (Android/iOS);
Wi-Fi kopuk değil. `WARN` exit code `10`, `FAIL` exit code `1`. Ölçümü video oynarken tekrarlayın.

## Performans (tüm cihazlar)

Pi 4B + tam stack için önerilen `.env` ayarları:

- `ADGUARD_FILTER_PROFILE=balanced` — `aggressive` (~2.4M kural) bellek ve lookup maliyeti yüksek
- `ADGUARD_BLOCKED_TTL=300` — engellenen domainleri 60s yerine 5 dk cache
- `ADGUARD_COVERAGE_AUDIT_ENABLED=false` — health timer’da 2000 satır audit kapalı; `make audit-dns` ile manuel
- `ADGUARD_AUTO_HEAL=false` — filter drift’te apply + `cache_clear` (ev DNS soğumasın)
- `ADGUARD_DNS_AUTO_HEAL=true` — DNS drift’te yalnız `apply-adguard-dns.sh` (TTL/upstream)
- `GATEWAY_VIDEO_DNS_PROBE=false` — rutin export’ta video DNS probe yok

Unbound cache `32m/64m` (2GB Pi). Health timer 5 dk, deprem poll 60s. Profil değişince `make adguard-tune`.

**Modem Wi-Fi (H3600P, 2026-09-02 uygulandı):** 5 GHz **80 MHz** kanal **44**, TX **%80** (DFS auto=112 ve 160 MHz jitter; %100 TX zayıf istemciyi 5 GHz’de tutuyordu). 2.4 GHz **20 MHz** kanal **1** kilit (Auto 12/13 seçmesin). Aynı SSID `Fenerbahçe`, Bant Geçiş açık, Mesh kapalı, misafir SSID kapalı. Zayıf istemci hâlâ 5 GHz’de takılırsa telefonu 2.4’e zorla veya AP ekle.

**Deploy regression:** Mac `.env` içinde `ADGUARD_FILTER_PROFILE=aggressive` kalırsa `deploy-code` Pi’yi geri çeker — `post-deploy-code` `ensure-dns-perf-profile.sh` ile `balanced`’a döndürür (`ADGUARD_ALLOW_AGGRESSIVE=true` ile korunur).

## Update

```bash
ssh "$PI_USER@$PI_STATIC_IP" 'REMOTE_DIR=~/pi-gateway bash ~/pi-gateway/scripts/pi/apply-adguard-dns.sh'
ssh "$PI_USER@$PI_STATIC_IP" 'REMOTE_DIR=~/pi-gateway bash ~/pi-gateway/scripts/pi/apply-adguard-filters.sh'
```

After deploy, `post-deploy` runs automatically: `wait-adguard-dns` → `apply-adguard-dns` → `apply-adguard-filters`.

## Boot note

After a Pi reboot, DNS port 53 may take ~30–90 seconds to open (filter loading). If the Mac uses the Pi as its only DNS server, wait for the Pi to be ready first.
