# Pi Gateway - Production Kurulum

Profesyonel, otomatik, tek komutlu kurulum.

## Gereksinimler

- Mac: Docker Desktop, SSH, rsync, python3
- Pi 4B: OS on **USB SSD** (128GB onerilir), ethernet, 5V/3A guc
- `.env` icinde guclu `AGH_ADMIN_PASSWORD` (min 12 karakter)

## Hizli kurulum (Pi acik)

```bash
cd ~/Documents/raspberrypi
cp .env.example .env
# .env duzenle: AGH_ADMIN_PASSWORD, TAILSCALE_AUTHKEY (opsiyonel)
make install
```

Script soracak veya `.env` icindeki `PI_HOST` ile baglanacak.

## Otomatik olan her sey

| Adim | Otomatik mi |
|------|-------------|
| Ag kesfi (gateway, subnet, static IP) | Evet |
| dhcpcd static IP | Evet |
| systemd-resolved port 53 fix | Evet |
| Docker + compose stack | Evet |
| AdGuard admin + upstream Unbound | Evet |
| Unbound recursive config | Evet |
| DNS rewrites (*.home) | Evet |
| Homepage + Uptime Kuma | Evet |
| Caddy reverse proxy | Evet |
| autoheal container recovery | Evet |
| log2ram + sysctl UDP tuning | Evet |
| DNS health timer (2 dk) | Evet |
| Gunluk backup timer | Evet |
| Tailscale (auth key varsa) | Evet |
| Smoke test (deploy sonu) | Evet |

## Elle yapilacak (1 kez)

### router-dns modu (varsayilan)
Router admin -> DNS Server -> Pi static IP

### adguard-dhcp modu (tam otomasyon)
`.env`: `NETWORK_MODE=adguard-dhcp`
Router DHCP kapat -> AdGuard tum cihazlara DNS verir

## SSD kurulum (eve varmadan oku)

1. SSD'yi USB 3.0 porta tak
2. Raspberry Pi Imager -> OS'i SSD'ye yaz
3. Imager: SSH enable, kullanici/sifre
4. Pi SSD'den boot et
5. `STORAGE_TYPE=ssd` (.env'de varsayilan)

## Uzaktan erisim (universiteden)

1. Tailscale auth key olustur: https://login.tailscale.com/admin/settings/keys
2. `.env` -> `TAILSCALE_AUTHKEY=tskey-...`
3. Deploy sonrasi Tailscale admin -> DNS -> Pi 100.x IP -> Override local DNS

## Komutlar

```bash
make validate   # Mac'te config dogrula (Pi kapali olabilir)
make discover   # Sadece ag kesfi
make render     # Config uret
make deploy     # Pi'ye gonder
make install    # Tam pipeline
```

## Sorun giderme

```bash
ssh pi@PI_IP 'cd ~/pi-gateway/compose && docker compose ps'
ssh pi@PI_IP 'cd ~/pi-gateway/compose && docker compose logs -f adguard'
ssh pi@PI_IP 'sudo journalctl -t pi-gateway-health -n 20'
```

Detayli mimari: [docs/ARCHITECTURE.md](docs/ARCHITECTURE.md)
