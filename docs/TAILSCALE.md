# Tailscale Uzaktan Erişim

## Kurulum (Pi)

Deploy sırasında `setup-tailscale-remote.sh` çalışır. Manuel:

```bash
ssh pi 'REMOTE_DIR=~/pi-gateway bash ~/pi-gateway/scripts/pi/setup-tailscale-remote.sh'
```

## Mac / iPhone

1. Tailscale uygulamasını kur
2. Aynı tailnet'e giriş yap
3. Pi'yi onayla: subnet `192.168.1.0/24` route

## DNS (`*.home` uzaktan)

Tailscale Admin → DNS → Nameservers:

- Split DNS: `home` → Pi Tailscale IP (`100.x.x.x`)
- **Override local DNS** açık

## Tailscale Serve (önerilen — Telegram uzaktan linkler)

Telefonda `https://gateway.home` mkcert sertifikasına güvenmez. Bunun yerine:

1. Admin'de Serve'i aç: deploy sırasında verilen `/f/serve` linki veya ACL
2. Pi'de: `bash scripts/pi/setup-tailscale-serve.sh`
3. Telegram menüsünde **🌐 Uzaktan** butonları: `https://pi-gateway.tailXXXX.ts.net/p/dns` vb.

```bash
make telegram-menu   # veya Pi'de scripts/pi/telegram-menu.sh
```

Teşhis: `bash scripts/pi/diagnose-remote-access.sh`

## ACL (önerilen)

`config/tailscale/acl.hujson.example` dosyasını [Access Controls](https://login.tailscale.com/admin/acls) sayfasına kopyala.

- Pi'ye etiket: `tag:pi-gateway`
- Kendi cihazlarına: `tag:owner-device`
- Misafir cihazlar Pi'ye erişemez

## SSH

```bash
ssh pi-ts          # Tailscale IP
ssh batu@100.x.x.x
```

## Güvenlik notu

UFW, `tailscale0` üzerinde yalnızca 22/80/443'e izin verir. Admin panelleri Caddy (`*.home`) üzerinden erişilir.
