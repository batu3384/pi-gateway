# Reklam Engelleme Stratejisi — Tasarım Spec

**Tarih:** 2026-07-19  
**Durum:** Onaylandı (Faz 1: router DNS, `adguard-dhcp` yok)  
**Karar:** AdGuard Home’da kal; Pi-hole migrasyonu ertelendi.

## Problem

Kullanıcı ağ genelinde reklam engellemenin “hiç işe yaramadığını” düşünüyor. Teşhis: AdGuard DNS motoru çalışıyor (Pi üzerinde `doubleclick.net` → `0.0.0.0`, ~%19 engelleme oranı, HaGeZi Pro++ + TIF Medium aktif). Sorun büyük olasılıkla:

1. **DNS bypass** — `NETWORK_MODE=router-dns` ile cihazlar Pi DNS’i atlayabilir
2. **Yapısal sınır** — YouTube, Instagram, TikTok feed reklamları DNS ile engellenemez (reklam ve içerik aynı domain/altyapı)

Pi-hole’a geçiş aynı DNS teknolojisini kullanır; YouTube/sosyal medya sorununu çözmez, yüksek migrasyon maliyeti getirir.

## Hedef

- Tüm LAN cihazlarının DNS sorgularının mümkün olduğunca `192.168.1.112` (AdGuard) üzerinden geçmesi
- Bypass kaynaklarının kapatılması (router ikincil DNS, cihaz DoH/Private DNS)
- DNS’nin yapamadığı platformlar için katmanlı çözümün net tanımı
- 1 hafta içinde ölçülebilir iyileşme (query log + kullanıcı gözlemi)

## Kapsam dışı (bu faz)

- Pi-hole migrasyonu
- `NETWORK_MODE=adguard-dhcp` (kullanıcı A seçeneği: düşük risk, router DNS önce)
- YouTube uygulamasında %100 reklamsızlık (DNS ile mümkün değil)

## Mimari

```
[Cihazlar] --DNS--> [ZTE Router DHCP: DNS=192.168.1.112 only]
                          |
                          v
                   [AdGuard :53] --upstream--> [Unbound :5335] --> Internet
                          |
                   [HaGeZi + user rules]
```

Katmanlar:

| Katman | Araç | Kapsam |
|--------|------|--------|
| 1 | AdGuard + Unbound | Ağ geneli, IoT, smart TV, 3. parti reklam domainleri |
| 2 | uBlock Origin (tarayıcı) | Masaüstü web, sayfa içi reklamlar |
| 3 | YouTube Premium / kabul edilen alternatif | Mobil YouTube uygulaması |

## Faz 1 — Teşhis (1 gün)

### Otomatik (Pi üzerinde)

```bash
# Engelleme çalışıyor mu?
dig +short @192.168.1.112 doubleclick.net A   # beklenen: 0.0.0.0
dig +short @8.8.8.8 doubleclick.net A         # karşılaştırma: gerçek IP

# Smoke (repo)
cd ~/pi-gateway && bash scripts/pi/smoke-test.sh  # adguard-block geçmeli
```

### Manuel cihaz kontrolü

Her cihaz için dns.home → Sorgu günlüğü’nde IP görünüyor mu?

| Cihaz | IP | Query log’da var mı? | Test sitesi reklamı |
|-------|-----|----------------------|---------------------|
| iPhone | 192.168.1.109 | | |
| Samsung | 192.168.1.100 | | |
| Mac/PC | | | |
| Smart TV | | | |

### Karar ağacı

- **Log boş** → bypass var → Faz 2 zorunlu
- **Log dolu, YouTube/IG reklam var** → Faz 3 (katman 2–3)
- **Log dolu, haber sitesi reklamı var** → liste veya tarayıcı katmanı

## Faz 2 — Router DNS sertleştirme (seçilen yol: A)

### ZTE router (hgw / 192.168.1.1)

1. Admin panel → **LAN / DHCP** ayarları
2. **Primary DNS:** `192.168.1.112`
3. **Secondary DNS:** **boş** veya `192.168.1.112` (8.8.8.8 / 1.1.1.1 **olmamalı**)
4. DHCP lease’leri yenile: cihazlarda Wi‑Fi kapat-aç veya uçak modu

### iPhone / iPad

- Wi‑Fi → ağ → DNS → **Manuel** → yalnızca `192.168.1.112`
- **Limit IP Address Tracking** → Kapalı (ev ağında test için)
- iCloud Private Relay → Kapalı (test için)

### Android

- **Private DNS** → Kapalı (veya evde Pi IP — Android Private DNS hostname ister, genelde “Kapalı” daha güvenilir)

### Chrome / Edge

- Ayarlar → Güvenlik → **Güvenli DNS kullan** → Kapalı

### Doğrulama

24 saat sonra AdGuard istatistikleri:

- `num_dns_queries` artmalı
- `num_blocked_filtering` / toplam oran ≥ %15 hedef (mevcut ~%19)

## Faz 3 — Katmanlı engelleme (DNS yetmediği yerler)

| Platform | DNS sonucu | Önerilen ek |
|----------|------------|-------------|
| YouTube app | Engellenmez | Premium veya (Android) ReVanced — ToS riski |
| Instagram / TikTok feed | Engellenmez | Tarayıcı + uBlock; uygulama sınırlı |
| Haber siteleri | Kısmen | uBlock Origin |
| Smart TV | Kısmen | AdGuard yeterli olabilir; agresif liste false positive izle |

**Önerilen tarayıcı eklentisi:** uBlock Origin (Firefox/Chrome)

## Başarı kriterleri

1. Tüm aktif cihazlar query log’da görünür
2. `dig @192.168.1.112` ile bilinen reklam domainleri `0.0.0.0`
3. Kullanıcı: haber sitesi / smart TV’de gözle görülür iyileşme
4. YouTube uygulaması için beklenti net: DNS tek başına yetmez

## Pi-hole karar kapısı (6 ay veya Faz 2–3 sonrası)

Pi-hole yalnızca şu durumlarda değerlendirilir:

- AdGuard tekrarlayan kararsızlık / bellek sorunu
- Kullanıcı bilinçli olarak Unbound+Pi-hole mimarisi istiyor
- Faz 2 tamamlandıktan sonra hâlâ query log boş (bypass devam)

Aksi halde AdGuard + mevcut script entegrasyonu (NetAlertX, n8n, smoke) korunur.

## Riskler

| Risk | Azaltma |
|------|---------|
| Router yanlış DNS → internet kesilir | Önce Pi static IP doğrula; router’da yedek DNS notu |
| Agresif listeler (HaGeZi) site kırar | dns.home → whitelist; query log ile false positive |
| Kullanıcı YouTube beklentisi | Spec ve iletişimde DNS sınırı açık |

## Sonraki adım (implementation plan)

1. Router DNS checklist scripti veya `docs/OPERATIONS.md` bölümü
2. İsteğe bağlı: `scripts/pi/diagnose-dns-bypass.sh` (dig + AdGuard API istatistik)
3. Kullanıcıya 24h sonra teşhis raporu

**Onay:** Kullanıcı 2026-07-19 — Seçenek **A** (router DNS önce, `adguard-dhcp` yok).
