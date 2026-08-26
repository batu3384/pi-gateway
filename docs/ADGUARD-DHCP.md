# AdGuard DHCP Mode

> **Canlı (2026-08-27):** ZTE relay LAN DISCOVER yuttu — AGH kira 0, ev IP kesti. Rollback yapıldı: modem **DHCP Açık**, DNS1=Pi, relay kapalı. `NETWORK_MODE=router-dns`. AdGuard DHCP **kapalı**. `adguard-dhcp` bu ZTE'de relay olmadan ev-keser.
>
> Rollback: modem **DHCP Sağlayıcısı → Sunucu Açık** **önce**, sonra AdGuard DHCP kapat. Tersi = kira bitince cihaz IP alamaz.

`NETWORK_MODE=adguard-dhcp` — Pi DNS+DHCP. Yeni lease DNS2=.1 yok. Eski ZTE lease bitene kadar DNS2 kalır (yenile / uçak modu).

## Prerequisites

1. **Modem DHCP kapat** (Yerel ağ → LAN → DHCP Sağlayıcısı — LAN Grubu Uygula değil)
2. Pi sabit IP (`dhcpcd` / rezerv)
3. UFW UDP/67 `eth0` (DISCOVER `0.0.0.0` — `from LAN_SUBNET` yetmez)
4. `render-config.sh` DHCP bloğu **veya** AGH `POST /control/dhcp/set_config` (yaml `enabled: true` kalmalı)

## .env

```env
NETWORK_MODE=adguard-dhcp
DHCP_RANGE_START=192.168.1.22
DHCP_RANGE_END=192.168.1.235
LAN_SUBNET_MASK=255.255.255.0
```

Pi IP (`PI_STATIC_IP`) aralıkta olsa AGH kendi adresini vermez.

## Setup

```bash
make render && make deploy
# Pi: AdGuard :67 dinliyor (`ss -ulnp | grep :67`)
# Modem: DHCP Sunucusu Kapalı → Uygula
```

## Rollback

1. Modem DHCP Sunucusu **Açık** + Uygula
2. `NETWORK_MODE=router-dns`
3. `make render && make deploy` (AdGuard DHCP kapanır)
4. Router DNS1 = Pi

## Risk

Pi düşer + modem DHCP kapalı → yeni cihaz IP alamaz. Eski lease bitene kadar çalışır.
IPv6: modem RA hâlâ `fe80::1` RDNSS 900s (radvd lifetime 0 savaşır; RFC 8106 last-RA).
