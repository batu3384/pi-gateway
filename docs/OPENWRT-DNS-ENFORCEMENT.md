# OpenWrt DNS enforcement geçişi

Bu dosya geçiş tasarımıdır; ZTE H3600P üzerinde otomatik değişiklik yapmaz.
Kalıcı enforcement için istemcilerin DHCP ve IPv6 RA kaynağı OpenWrt olmalıdır.

## Hedef akış

```text
ZTE (bridge/ONT veya izole upstream)
  -> OpenWrt LAN DHCP + tek IPv6 RA
  -> LAN istemcileri
  -> TCP/UDP 53 redirect -> Pi AdGuard Home
  -> Unbound DoT upstream
```

ZTE bridge desteklemiyorsa OpenWrt WAN'ı ZTE LAN'ına alın ve double-NAT/DMZ
etkisini önce ayrı bir test VLAN'ında doğrulayın. ZTE LAN'ında kalan istemciler
OpenWrt kurallarıyla korunmaz.

## Uygulama sırası

1. Pi IPv4 DNS ve stabil `PI_IPV6_ULA` adresini kaydedin. Pi'de `:53` ve ULA
   DNS cevabını doğrulayın.
2. OpenWrt test LAN/VLAN'ında DHCP Option 6'yı yalnız Pi IPv4 adresiyle yayınlayın.
   İkinci resolver eklemeyin.
3. OpenWrt RA/RDNSS'i yalnız Pi ULA ile yayınlayın. ZTE'nin ikinci RA/DNS
   reklamı LAN'a ulaşmamalı; aksi durumda sonuç `best-effort` kabul edilir.
4. Önce LAN'dan Pi'ye doğrudan DNS erişimini, sonra redirect'i açın.
5. LAN TCP/UDP `53` trafiğini Pi'ye DNAT edin; WAN'a çıkan doğrudan `53` ve
   `853` trafiğini reddedin. Pi'nin Unbound upstream'i DoT `853` olduğundan
   WAN `53` reddi Unbound yapılandırılmadan uygulanmaz.
6. `make audit-dns` ve gerçek cihaz testleri geçtikten sonra VLAN'ı kademeli
   büyütün.

OpenWrt firewall redirect/rule hedefi Pi'nin LAN adresi olmalıdır. Örnek
mantık:

```text
LAN -> TCP/UDP 53  DNAT  PI_STATIC_IP:53
LAN -> TCP/UDP 53  WAN   REJECT
LAN -> TCP/UDP 853 WAN   REJECT
```

Bu kurallar `radvd` veya DHCP kaynağını değiştirmez; DHCP/RA tekliği ayrıca
sağlanmalıdır. Bilinen DoH hostları AdGuard `doh.txt` ile engellenir. Bilinmeyen
HTTPS resolver, uygulamaya gömülü resolver ve MITM gerektiren trafik için tam
garanti yoktur.

## Geçiş doğrulama kapısı

- DHCP OFFER: DNS yalnız Pi IPv4.
- İstemci RA/RDNSS: Pi ULA; ikinci RA/DNS yok.
- `dig @PI_STATIC_IP example.com A` başarılı.
- İstemcinin public `:53` denemesi başarısız; Pi DNS çalışır.
- TCP/UDP `853` başarısız.
- AdGuard query log'da her aktif cihaz görünür.
- YouTube/Instagram medya regression seti geçer.
- Pi DNS durduğunda varsayılan politika fail-closed; modem fallback yalnız
  açık opt-in ile kullanılır.

## Rollback

Pi DNS veya staged VLAN testi başarısızsa OpenWrt redirect/reject kurallarını
geri alın, eski DHCP/RA kaynağını tek başına bırakın ve istemcilerde lease
yenileyin. ZTE paneline yazma işlemi bu proje tarafından yapılmaz.
