# AdGuard DHCP Modu

`NETWORK_MODE=adguard-dhcp` ile Pi hem DNS hem DHCP sunar. Tüm cihazlar otomatik Pi DNS kullanır.

## Ön koşullar

1. Router’da **DHCP kapatılır** (yalnızca Pi dağıtır)
2. Pi static IP router’da rezerve veya dhcpcd ile sabit
3. `render-config.sh` DHCP bloğunu `AdGuardHome.yaml` içine yazar

## .env

```env
NETWORK_MODE=adguard-dhcp
DHCP_RANGE_START=192.168.1.100
DHCP_RANGE_END=192.168.1.200
LAN_SUBNET_MASK=255.255.255.0
```

## Kurulum

```bash
make render && make deploy
```

## Router ayarı

1. Router admin → DHCP Server → **Disabled**
2. Pi ethernet ile bağlı kalsın
3. Tek aktif DHCP: AdGuard

## Geri dönüş

1. `NETWORK_MODE=router-dns`
2. `make render && make deploy`
3. Router DHCP’yi tekrar aç
4. Router DNS = Pi static IP

## Risk

Yanlış DHCP aralığı veya Pi kapalıyken router DHCP kapalı → ağda yeni cihaz IP alamaz. İlk kurulumda router DNS modunu tercih edin; DHCP moduna geçişi planlı yapın.
