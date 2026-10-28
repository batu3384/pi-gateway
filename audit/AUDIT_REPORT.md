# Pi Gateway — mühendislik denetimi

Tarih: 2026-10-28. Kapsam: `/Users/batuhanyuksel/Documents/raspberrypi` (git `master`, commit `7043b66` ve sonrası yerel ağaç). Üretim Pi bu geçişte yoklandı. `.gitignore` değiştirilmedi. `audit/` izlenmeyen çalışma alanıdır.

## Bölüm 1: Proje Bağlamı, Tehdit Modeli ve Mühendislik Karnesi

**Çıkarılan bağlam.** Tek düğümlü ev DNS ve panel geçidi. Raspberry Pi 4B, SD kök + USB SSD veri. AdGuard Home (`:53`, host network) filtreler; Unbound (`127.0.0.1:5335`) DoT ile Quad9/AdGuard DNS’e iletir. Caddy `*.home` panellerini TLS ve Basic auth ile verir. n8n, NetAlertX, CrowdSec, Uptime Kuma, Grafana, Homepage, Telegram/Hermes operasyon katmanıdır. Kod bash ve Python’dur; ayrı bir web uygulaması yoktur.

**Tehdit modeli.** Saldırgan modeli: LAN’da kısmen güvenilen istemci, internetten SSH/panel, ele geçirilmiş bir konteyner, kaybolan yedek. En kritik hata: ev DNS’inin boş kalması, filtresiz çözülmesi veya `*.home` rewrite’ının silinmesi. İkinci kritik hata: restic repo açılamazsa felaket kurtarma iddiası boştur. Modem (ZTE H3600P) aynı L2’de ikinci DNS ve IPv6 RA yayınlar; Pi bu paketleri kesemez. Bu tavan kod hatası değil, yerleşim sınırıdır.

**Puanlar (100).** Rubrik: 90–100 üretime hazır küçük iş; 75–89 çalışır, orta borç; 50–74 ciddi boşluk; 0–49 canlıya çıkmamalı. Sistem zaten evde çalışıyor. Puan “sıfırdan yayın” değil, “bu haliyle bırakılırsa risk”tir.

| Kriter | Puan | Gerekçe |
|---|---:|---|
| Mimari ve kod kalitesi | 76 | Katmanlar (DNS / panel / yedek / sağlık) yazılı. Üç dosya 800–1193 satır. Shell sözleşmeleri grep ile kilitli. |
| İş mantığı ve kararlılık | 71 | `:53` yarım bind kapatılmış. DNS2/IPv6 RA ve USB overlay hâlâ kesinti üretir. Restic açılışı şüpheli. |
| Güvenlik ve tedarik zinciri | 78 | 196 commit gitleaks temiz. İmajlar digest pinli. Caddy auth var. Docker köprüsü yönetim portuna açık. Action tag pinli değil. |
| Performans ve kaynak | 74 | DoT, cache TTL, AAAA kapatma var. Docker kökü USB’de. Fallback thread-per-query. SD doluluk prune’u sınırlı. |
| UX | 70 | Paneller ve durum kartı var. Homepage hata/boş durumu yok. “Yavaş internet” aslında DNS kaçışı; panel bunu anlatmıyor. |
| Test, gözlem, üretime hazırlık | 79 | CI: shellcheck, gitleaks, `validate.sh`. Health timer ve SLO var. Testlerin çoğu metin sözleşmesi. Drill, bozuk repoda kırmızıya düşer. |

## Bölüm 2: Bozuk Akışlar, İş Mantığı Hataları ve Eşzamanlılık

**[Önem: YÜKSEK]** — **[Güven: Muhtemel]** — `scripts/mac/backup-restore-drill.sh:58-59` ve `scripts/pi/restic-repair.sh:52-53`

```bash
restic -r "$LOCAL_REPO" restore "$DRILL_SUBSET" --target "$tmpdir" || die "restic restore basarisiz"
```

```bash
log "HATA: restic check basarisiz — corrupt repo; yedek klasorunu .corrupt.* tasiyip RESTIC_ALLOW_REINIT=true ile yeniden init"
```

* **Sorun & Tetiklenme Yolu:** Drill, restic nonzero dönünce tüm işi başarısız sayar ve Pi’ye failure marker yazar (`die` → `record_failure`). Repair check de fail olursa reinit ister; bozuk paketi kendisi ayıklamaz. 2026-10-21 operasyonunda son snapshot (`d24f1b17`) 2207 öğeden 52 blob’da `ciphertext verification failed` verdi (Prometheus chunk, Kuma db, CrowdSec GeoIP). Bu denetim restore’u tekrar çalıştırmadı.
* **Etki:** Offsite “var” görünür, geri açılış fail olur. Health SLO drill’i kırmızı tutar. Gerçek disk ölünce config+data birlikte dönmez.
* **Mühendislik Çözümü:** `restic check` çıktısındaki bozuk pack’leri ayır. Temiz bir repo’ya yalnız config+compose+gerekli data ile yeni snapshot al. Drill’i o snapshot’ta geçir. Eski corrupt snapshot’ı restore hedefi yapma. Reinit’den önce Mac kopyasının sağlam olduğunu doğrula.

**[Önem: YÜKSEK]** — **[Güven: Doğrulandı]** — `docs/ARCHITECTURE.md:35-36`

```text
DNS1 = Pi .112          DNS2 = .1 (ZTE inject, panel yok sayilir)
IPv6 RDNSS = fe80::1    (+ Pi ULA RA, last-RA savasi)
```

* **Sorun & Tetiklenme Yolu:** İstemci DHCP DNS2 veya modem RA’sındaki `fe80::1` ile çözer. Pi AdGuard AAAA vermez; modem verir. İstemci RFC 8305 ile v6’yı dener, takılır, v4’e düşer.
* **Etki:** Reklam kaçar. Video “bir yavaşlar bir düzelir”. Pi CPU’su suçlanmaz; sorgu Pi’ye hiç gelmez.
* **Mühendislik Çözümü:** Yazılım tavanı bu. Kalıcı kilit: OpenWrt (tek DHCP, tek RA, LAN `:53` DNAT) veya cihaz bazında yalnız Pi DNS. ZTE panel Apply, VoIP riski nedeniyle kod yolu değil.

**[Önem: ORTA]** — **[Güven: Doğrulandı]** — `scripts/lib/dns-dot-proxy.py:217-219`

```python
def _spawn(target, args) -> None:
    if not _INFLIGHT.acquire(blocking=False):
        return
```

* **Sorun & Tetiklenme Yolu:** Eşzamanlı sorgu 64’ü aşınca UDP paketi sessiz düşer. SERVFAIL yok.
* **Etki:** USB kopunca fallback ayaktayken LAN fırtınası timeout olur. İstemci modem DNS2’ye kaçar.
* **Mühendislik Çözümü:** Doluyken kısa SERVFAIL dön. Üst sınır için `ThreadPoolExecutor`. Varsayılan 64 ev için yeterli; davranışın sessiz olması değil.

**[Önem: DÜŞÜK]** — **[Güven: Doğrulandı]** — `scripts/pi/dns-host-fallback.sh:68` (shellcheck SC2034, 1/1 uyarı)

```bash
for i in $(seq 1 "${DNS_FALLBACK_WAIT_DIE_SEC:-12}"); do
```

* **Sorun & Tetiklenme Yolu:** `i` yalnız döngü sayacı. `shellcheck -S warning` bu dosyada tek uyarıyı verdi.
* **Etki:** Çalışmayı bozmaz. CI warning eşiğinde kırmızıya yakın.
* **Mühendislik Çözümü:** `for _ in ...` yap.

### Düşük öncelik özeti

| Konu | Güven | Not |
|---|---|---|
| `BIND_WAIT_SEC=0` sonsuz bekleme | Doğrulandı | AGH `:53` tutarken unit ayakta kalır. `ensure` TCP rewrite ile keser. Bilinçli tavan. |
| Bandit B608 Hermes SQL | Şüpheli, elendi | `open_tg` sabit literal. Kullanıcı girdisi yok. |

## Bölüm 3: Yarım Kalan Özellikler, Kopuk Uçlar ve Ölü Kodlar

**[Önem: ORTA]** — **[Güven: Doğrulandı]** — `scripts/mac/sync-rendered-configs.sh:79-83`

```bash
cp /tmp/homepage-services.yaml "${R}/config/homepage/services.yaml"
[[ -f /tmp/Caddyfile ]] && cp /tmp/Caddyfile "${R}/config/caddy/Caddyfile"
```

* **Sorun & Tetiklenme Yolu:** AdGuard yaml’ı artık varsa ezilmiyor. Homepage `services.yaml` her `sync-rendered-configs` çağrısında Mac kopyasıyla değişir ve homepage restart olur. Caddyfile de aynı.
* **Etki:** Pi üzerinde elle düzeltilmiş panel linki bir sonraki deploy’da gider. Homepage birkaç saniye 502.
* **Mühendislik Çözümü:** AdGuard’daki “dosya varsa yazma” kuralını homepage için de uygula. Caddy yalnız şablon hash’i değiştiyse kopyalansın.

Kod tabanında `TODO`/`FIXME` yok (2026-09-17 envanteri ve bu tarama). Bu, işin bittiği anlamına gelmez. Ölü dosya iddiası için import grafı tamamlanmadı; toplu silme önerilmez.

### Düşük öncelik özeti

| Konu | Not |
|---|---|
| Wiki “Now” satırı | `wiki/Roadmap.md` wiki sync hâlâ Now. Kod yolu `scripts/sync-wiki.sh`. Ürün DNS’ini kesmez. |

## Bölüm 4: Uygulama Güvenliği, Tedarik Zinciri ve Veri Gizliliği

**[Önem: ORTA]** — **[Güven: Doğrulandı]** — `scripts/pi/setup-firewall.sh:157-163` (aynı desen docker0 fallback’te de var)

```bash
sudo ufw allow from "$compose_subnet" to any port 8080 proto tcp comment 'pi-gateway docker-adguard'
sudo ufw allow from "$compose_subnet" to any port "$netalert_port" proto tcp comment 'pi-gateway docker-netalertx'
sudo ufw allow from "$compose_subnet" to any port "$graphql_port" proto tcp comment 'pi-gateway docker-netalertx-graphql'
```

* **Sorun & Tetiklenme Yolu:** Caddy Basic auth, tarayıcıyı keser. Aynı hosttaki herhangi bir köprü konteyneri (n8n dahil) UFW izniyle AdGuard `:8080` ve NetAlertX UI/GraphQL’e gider. AdGuard host network’tedir (`compose/docker-compose.yml:20`).
* **Etki:** Ele geçirilmiş workflow, panel parolasını Caddy’yi atlayarak deneyebilir. GraphQL, Caddy oturumundan bağımsızdır.
* **Mühendislik Çözümü:** 8080 ve 20211’i yalnız Caddy’nin bağlandığı adrese sıkılaştır. n8n’i bu subnet’ten çıkar veya admin portlarını docker bridge’e kapat. GraphQL’i loopback’te tut.

**[Önem: ORTA]** — **[Güven: Doğrulandı]** — `.github/workflows/validate.yml:12` ve `:23`

```yaml
- uses: actions/checkout@v4
- uses: gitleaks/gitleaks-action@v2
```

* **Sorun & Tetiklenme Yolu:** Tag hareket ederse bir sonraki CI, başka bir commit çalıştırır. `dependabot.yml` yalnız `package-ecosystem: docker`. Action ekosistemi yok.
* **Etki:** CI’ya kod enjekte edilirse gitleaks adımı da o işin içindedir. Ev sırrı CI’da yok; risk tedarik zinciri.
* **Mühendislik Çözümü:** Checkout ve gitleaks action’ını commit SHA ile pinle. Dependabot’a `github-actions` ekle.

**[Önem: DÜŞÜK]** — **[Güven: Doğrulandı]** — `docs/SECURITY.md:40`

```text
Restic is encrypted; password lives in .env on the same Pi (co-location accepted).
```

* **Sorun & Tetiklenme Yolu:** Pi kökü okunursa restic parolası da okunur. Offsite kopya o parola ile açılır.
* **Etki:** Disk çalınması yedekleri de açar. Tasarım bunu kabul etmiş.
* **Mühendislik Çözümü:** Offsite parola ayrı kalsın (Mac keychain). Pi `.env` içindeki parola yalnız yerel repo için olsun.

Gitleaks: 196 commit, 0 leak (`/tmp`, bu geçiş). `.env` git geçmişinde yok. Bu bir bulgu değil, kapanmış kontroldür.

### Düşük öncelik özeti

| Konu | Güven | Not |
|---|---|---|
| Fallback DoT filtresiz | Doğrulandı | AGH yokken tasarım böyle. Kısmi bind kapalı. |
| Bandit B108 `/tmp` | Şüpheli | Test ve bülten yolu. Dünya yazılabilir tmp. Düşük. |

## Bölüm 5: Yazılım Mimarisi, Performans ve Kaynak Yönetimi

**[Önem: YÜKSEK]** — **[Güven: Doğrulandı]** — `compose/docker-compose.yml:16-20` ile `docs/ARCHITECTURE.md` depolama notu ve `ENABLE_DOCKER_SSD`

```yaml
adguard:
  image: adguard/adguardhome@sha256:a2085b04bbfc4759e68fa1d13d4e1558aede67c783c55820e036a95a36dd3ebf
  network_mode: host
```

* **Sorun & Tetiklenme Yolu:** Docker kökü USB SSD üzerindeyse (`ENABLE_DOCKER_SSD=true`) JMicron kopunca dockerd ve AdGuard birlikte ölür. Host fallback `:53`’ü tutar; filtre ve rewrite gitmez.
* **Etki:** Ev DNS’i reklamlı DoT’a düşer veya, fallback da yoksa, boşalır. Tekrarlayan “internet gitti” hissi.
* **Mühendislik Çözümü:** Overlay’i SD’ye almak için SD’de yer gerekir (kök ~%70). Kalıcı donanım: ASMedia kutu. Yazılım tavanı fallback’tir; onu kaldırma.

**[Önem: ORTA]** — **[Güven: Doğrulandı]** — `scripts/lib/adguard-filters.py:1` (1193 satır), `scripts/lib/ssd-alive.sh` (1084), `scripts/pi/health-check.sh` (785), `scripts/lib/notify.sh` (881)

```python
#!/usr/bin/env python3
```

* **Sorun & Tetiklenme Yolu:** Filtre ön kontrol, API mutasyonu, rollback ve self-check aynı modülde. Health, DNS, yedek SLO ve konteyner tamiri aynı scriptte.
* **Etki:** Bir sağlık yamasının filtre veya yedek yolunu kırması kolay. Yeni kişi trust boundary’yi kaçırır.
* **Mühendislik Çözümü:** Davranış testleri dururken böl. Önce preflight/state, sonra apply. Health’ten SLO ve docker tamirini ayır. Tek seferde yeniden yazma.

**[Önem: ORTA]** — **[Güven: Doğrulandı]** — `scripts/lib/dns-dot-proxy.py:32-33`

```python
# ponytail: thread-per-query. Ceiling LAN storm; upgrade ThreadPoolExecutor.
MAX_INFLIGHT = int(os.environ.get("DNS_FALLBACK_MAX_INFLIGHT", "64"))
```

* **Sorun & Tetiklenme Yolu:** Her sorgu bir thread ve yeni TLS el sıkışması (üst akışa). 0.5 s bind denemesi AGH ayaktayken de döner.
* **Etki:** Fallback dakikalarca kalırsa Pi CPU ve soket tüketir. Normal AGH yolunda bu kod çalışmaz.
* **Mühendislik Çözümü:** TLS oturumunu upstream başına yeniden kullan. Bind beklemesini systemd `Restart=` ile değil, tek sleep ile tut; log’u bir kez yaz (zaten `logged_wait`).

### Düşük öncelik özeti

| Konu | Not |
|---|---|
| Compose digest pin | İmajlar SHA256. Tag kayması yok. İyi. |
| Unbound healthcheck kapalı | Bilinçli. WAN `:53` drop health döngüsünü kesmiş. Host dig `:5335` asıl probe. |

## Bölüm 6: Arayüz, Kullanılabilirlik ve Durum Yönetimi

**[Önem: ORTA]** — **[Güven: Doğrulandı]** — `config/homepage/services.yaml.template:49-51`

```yaml
- customapi:
    label: Gateway durumu
    url: http://gateway-state/state.json
```

* **Sorun & Tetiklenme Yolu:** `gateway-state` kapalıysa veya JSON boşsa Homepage’in bu şablonda boş/hata durumu yok. Health sonradan konteyneri açar; ilk ekran kırık kalır.
* **Etki:** Sahip paneli “depolama / DNS kapsam” boş görür ve DNS’in sağlam olduğunu sanır.
* **Mühendislik Çözümü:** Widget için timeout ve “durum yok” metni. `gateway-state` `restart: unless-stopped` yetmezse health start’ı (kodda var) log’da görünür kalsın.

**[Önem: ORTA]** — **[Güven: Doğrulandı]** — `docs/ARCHITECTURE.md:52`

```text
Pi **LAN gateway değil.** Aynı L2’de `192.168.1.1:53` Pi’den geçmez.
```

* **Sorun & Tetiklenme Yolu:** Kullanıcı yavaş videoyu “Pi bozuldu” diye okur. Arayüz, sorgunun modem DNS’ine gittiğini göstermez.
* **Etki:** Yanlış tamir (filtre, restart). Asıl kaçış durur.
* **Mühendislik Çözümü:** Homepage kartına tek satır: “DHCP DNS2 ve IPv6 DNS modemde. Bu Pi’yi yavaşlatmaz.” Ayrı bir uygulama değil.

Ayrı bir SPA yok. Loading/skeleton/error boundary beklentisi bu repoda yok. Paneller Caddy Basic auth arkasında. `devices.home` şablonu da auth taşıyor.

### Düşük öncelik özeti

| Konu | Not |
|---|---|
| Telegram durum kartı | Operatör arayüzü. Evdeki TV/telefon DNS kaçışını göstermez. |

## Bölüm 7: Dayanıklılık, Gözlemlenebilirlik, Test ve CI/CD

**[Önem: ORTA]** — **[Güven: Doğrulandı]** — `scripts/pi/crowdsec-ban-diary.sh:27-29`

```bash
raw="$(docker exec crowdsec cscli decisions list -o json 2>/dev/null || true)"
body="$(printf '%s\n' "$raw" | python3 "$FORMAT_PY" || true)"
[[ -n "${body// }" ]] || { log "ban yok — atlandi"; exit 0; }
```

* **Sorun & Tetiklenme Yolu:** `cscli` çökerse veya JSON bozuksa unit başarıyla çıkar ve “ban yok” der.
* **Etki:** Gece defteri sessizce boş kalır. Ban varken de “yok” sanılır.
* **Mühendislik Çözümü:** `cscli` nonzero ise exit 1 ve journal’a stderr. Boş liste `[]` ise exit 0. İkisini ayır.

**[Önem: ORTA]** — **[Güven: Doğrulandı]** — `.github/workflows/validate.yml:31-37`

```yaml
- name: Full local validation
  run: |
    cp .github/ci.env.fixture .env
    ./scripts/mac/validate.sh
```

* **Sorun & Tetiklenme Yolu:** CI, sözleşme grep’leri ve self-check çalıştırır. Pi’de `:53`, USB kopması veya restic restore yok. Birçok test, dosyada string arar.
* **Etki:** “CI yeşil” üretim DNS’inin sağlam olduğu anlamına gelmez. 2026-10-21 UDP bölünmesi ancak canlı `ss` ile görüldü; sonraki `bind_ready` testi bunu kilitledi.
* **Mühendislik Çözümü:** `dns-dot-proxy` için yüksek portta bind birim testi (CI’da `:53` değil). Restic için küçük fixture repo drill. Canlı Pi’yi CI’ya bağlama.

**[Önem: ORTA]** — **[Güven: Doğrulandı]** — `scripts/mac/backup-restore-drill.sh:35` (`die` failure marker yazar)

```bash
die() { echo "[backup-drill] HATA: $*" >&2; record_failure; exit 1; }
```

* **Sorun & Tetiklenme Yolu:** Bozuk blob, marker’ı “son deneme fail” yapar. Health bunu SLO sanır. Başarılı config restore ile bozuk media dosyası ayrılmaz.
* **Etki:** Operatör her health’te kırmızı görür. Gerçek config yedeği sağlam olsa bile alarm aynıdır.
* **Mühendislik Çözümü:** Restore’u iki kapıya böl: config+compose zorunlu, data içindeki `*.bak*` / prometheus chunk uyarı. Failure marker yalnız config yoksa yazılsın.

Shellcheck bu geçişte 1 uyarı verdi (Bölüm 2). Health timer, journal `FAIL`/`SLO` ayrımı ve Uptime Kuma push kodda var.

### Düşük öncelik özeti

| Konu | Not |
|---|---|
| Graceful shutdown | systemd `Restart=` ve compose `unless-stopped`. Ayrı bir process supervisor yok. Bu ölçekte yeterli. |

## Bölüm 8: Sektör Kıyaslaması ve Ürün Geliştirme Önerileri

Bu bölüm bulgu listesinden bağımsızdır. Konum: tek ev, tek Pi, AdGuard + Unbound DoT, modem DHCP’ye bağlı.

| Kaynak | Tarih | Ne diyor | Bu repoya etkisi |
|---|---|---|---|
| [Martin Hicks — AdGuard ve Unbound](https://martinhicks.dev/articles/adguard-unbound-dns-home) | May 2026 güncellemesi | Yazar Unbound’u kapattı; soğuk önbellek evi yavaşlattı. AdGuard doğrudan public resolver’a gidiyor. | Sizde Unbound DoT ile duruyor. Soğuk sorgu şikayeti olursa upstream’i AdGuard DoT’a indirmek meşru bir ürün kararı. Gizlilik geri gider. |
| [selfhosting.sh — AdGuard Home](https://selfhosting.sh/apps/adguard-home-dns/) | sayfa 2026’da erişildi | DoT/DoH/DoQ istemciye şifreli DNS vermek ayrı sertifika ister. | Ev içi `:53` yeterli. Dışarı DoH açmak yeni bir yüzeydir; şimdi ekleme. |
| [MakeUseOf — Unbound DoT](https://www.makeuseof.com/last-piece-added-home-dns-stack-most-important/) | 2026 | Quad9 DoT, ISP’den gizler; güveni tek operatöre taşır. | Sizin Unbound forward’unuz bu modelde. Doğru yerde. |
| [OpenWrt DNS hijack](https://openwrt.org/docs/guide-user/firewall/fw3_configurations/intercept_dns) | wiki, 2026-10-28 okundu | LAN `:53` DNAT, router kendisi L2/L3 kapısıysa çalışır. | Pi kapı değil. Bu özellik ancak OpenWrt kutusunda. |
| [OpenWrt forumu](https://forum.openwrt.org/t/vlans-security-and-dns/244981/12) | 2026-01-06 | Hijack bile DoH/gömülü çözücüyü kesmez. | “Tüm ev kilit” iddiası OpenWrt ile de bitmez. Ürün metninde böyle yazma. |
| [RFC 8305](https://www.rfc-editor.org/info/rfc8305/) | Aralık 2017, hâlâ güncel | AAAA pozitifse v6 bağlantısı önce başlar. | Modem AAAA verince gecikme buradan gelir. |

Ürüne eklenecekler (kod borcu değil):

1. Tek RA / tek DHCP DNS (OpenWrt veya eşdeğeri). En yüksek kullanıcı etkisi.
2. Homepage’de “sorgu Pi’ye gelmedi” satırı.
3. Restic’i config ve şişkin zaman serisinden ayıran iki repo. Drill yalnız config’te her gece yeşil kalabilir.
4. İstemci DoH’u bilinçli kapatma notu (tarayıcı Private DNS). Kodla kapanmaz.

## Bölüm 9: Fazlandırılmış Mimari Eylem Planı

**Faz 1 — Acil.** Restic’i doğrula (Bölüm 2, drill + repair). Bozuk pack duruyorsa yeni repo ve bir başarılı drill. USB kablo/kutu kararı (Bölüm 5); yazılım fallback’i silme.

**Faz 2 — Temizlik.** Homepage/Caddy sync’ini koşullu yap (Bölüm 3). CrowdSec günlüğünde `cscli` hatasını “ban yok”dan ayır (Bölüm 7). SC2034 (Bölüm 2).

**Faz 3 — Mimari.** Docker bridge → 8080/20211 sıkılaştır (Bölüm 4). `adguard-filters.py` ve `health-check.sh` bölünmesi, davranış testleri dururken (Bölüm 5). Fallback’te TLS yeniden kullanım ve dolu kuyrukta SERVFAIL (Bölüm 2 ve 5).

**Faz 4 — Kalite ve ürün.** Action SHA pin + Dependabot `github-actions` (Bölüm 4). CI’da yüksek port DNS bind testi ve küçük restic fixture (Bölüm 7). Homepage durum metni (Bölüm 6). OpenWrt ancak ayrı proje (Bölüm 8). Offsite restic parolasını Pi `.env`’den ayırma (Bölüm 4, düşük).

## Bölüm 10: Denetim Kapsam Beyanı

1. **Tam okunan.** `docs/ARCHITECTURE.md`, `docs/SECURITY.md`, `compose/docker-compose.yml` (ilk 120 satır ve adguard/caddy/homepage), `.github/workflows/validate.yml`, `.github/dependabot.yml`, `scripts/lib/dns-dot-proxy.py`, `scripts/pi/dns-host-fallback.sh`, `scripts/pi/crowdsec-ban-diary.sh`, `scripts/pi/prune-sd-space.sh`, `scripts/pi/setup-firewall.sh` (150–186), `scripts/pi/setup-tailscale-panel-ports.sh` (1–50), `scripts/mac/sync-rendered-configs.sh`, `scripts/mac/backup-restore-drill.sh` (50–84), `scripts/pi/restic-repair.sh` (45–57), `scripts/lib/hermes-session-hygiene.py` (30–62), `config/homepage/services.yaml.template` (44–51), `audit/NOTES.md`.

2. **Kısmen veya atlanan.** `scripts/lib/adguard-filters.py` (1193) ve `scripts/lib/ssd-alive.sh` (1084) satır satır okunmadı; boyut ve önceki denetim notu kullanıldı, bu raporda yalnız boyut bulgusu var. `scripts/pi/health-check.sh` seçili bölgeler. `config/adguard/AdGuardHome.yaml` üretilmiş runtime; git’te şablon okundu, canlı yaml açılmadı (sır). `data/`, sertifikalar, `.env` okunmadı. Üretim Pi’ye SSH yok.

3. **Koşan komutlar.** `gitleaks detect` → 0 leak, 196 commit. `shellcheck -S warning scripts/pi/*.sh scripts/mac/*.sh scripts/lib/*.sh` → 1 uyarı. `bandit -ll -ii -r scripts/lib scripts/pi` → High yok. `wc -l` büyük dosyalar. `git log` `.env`, `AKIA`, `BEGIN OPENSSH PRIVATE` → boş. Hepsi salt okunur; rapor `/tmp`.

4. **Koşulmayan.** `npm`/`pip`/`cargo`/`go` yok, o tarayıcılar yok. `semgrep`, `trivy`, `osv-scanner`, `trufflehog`, `pip-audit` bu ortamda çalıştırılmadı. Canlı `:53`, health ve restic restore bu geçişte tekrarlanmadı. `validate.sh` tüm ağacı yazmadan koşulmadı (CI fixture `.env` yazar).
