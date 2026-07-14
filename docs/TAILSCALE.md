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

Böylece `gateway.home`, `logs.home` vb. uzaktan da çalışır.

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
