# DNS reklam engelleme — sinirlar ve stack

## Neden telefon AdGuard daha cok engeller?

| Katman | Telefon AdGuard | Pi AdGuard Home |
|--------|-----------------|-----------------|
| DNS host engeli | Var | Var (bu proje) |
| HTTPS icerik (path/query) | Var (yerel VPN/proxy) | **Yok** |
| CSS element hiding | Var | **Yok** |
| Scriptlet / JS enjeksiyon | Var | **Yok** |

Sonuc: Ayni domain uzerinden gelen reklamlar (YouTube `googlevideo.com`, bazi uygulama ici reklamlar, sayfa ici iframe path'leri) DNS ile engellenemez. Bu normal; DNS-only mimari siniri.

## Mevcut DNS stack

1. **HaGeZi Pro++** — ana reklam/tracker listesi (OISD + digerleri zaten icinde)
2. **HaGeZi TIF Medium** — malware/phishing (Pi 4GB icin medium; full TIF RAM'i zorlar)
3. **AdGuard DNS Popup Hosts** — popup hostlari
4. **Apple / Windows / Samsung tracker** — cihaz telemetrisi
5. **User rules** — Google Ads, DoubleClick, Criteo, Taboola, Gemius vb. `$important`

OISD Big bilerek yok: Pro++ ile cift yuk; Pi RAM'i israf eder.

## Tarayici / YouTube icin

DNS yetmezse cihazda ekle:

- Safari: AdGuard for Safari / uBlock Origin Lite
- Chrome/Firefox: uBlock Origin
- YouTube: tarayici eklentisi veya SponsorBlock (DNS cozmez)

## Guncelleme

```bash
ssh "$PI_USER@$PI_STATIC_IP" 'REMOTE_DIR=~/pi-gateway bash ~/pi-gateway/scripts/pi/apply-adguard-dns.sh'
ssh "$PI_USER@$PI_STATIC_IP" 'REMOTE_DIR=~/pi-gateway bash ~/pi-gateway/scripts/pi/apply-adguard-filters.sh'
```

Deploy sonrasi `post-deploy` otomatik calistirir: `wait-adguard-dns` → `apply-adguard-dns` → `apply-adguard-filters`.

## Boot notu

Pi yeniden basladiginda DNS port 53'un acilmasi ~30-90 sn surebilir (filtre yukleme). Mac tek DNS olarak Pi kullaniyorsa once Pi'nin hazir olmasini bekle.
