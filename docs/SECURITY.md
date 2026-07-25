# Güvenlik Modeli

## Varsayımlar

- Ev LAN’ı (`192.168.1.0/24`) kısmen güvenilir
- DNS ve admin panelleri Pi üzerinde toplanmış
- İnternet tehditleri SSH ve servis portlarına yönelir

## Katmanlar

| Katman | Bileşen |
|--------|---------|
| Ağ | UFW (LAN-scoped), fail2ban SSH |
| Tehdit | CrowdSec + firewall bouncer |
| Uygulama | Servis bazlı şifreler (Dozzle, Forgejo, Kuma, Syncthing GUI) |
| DNS | AdGuard filtre + Unbound |
| Uzaktan | Tailscale (opsiyonel) |

## HTTP riski

`*.home` trafiği varsayılan olarak **HTTP**. LAN dinleyicisi veya misafir WiFi ile şifreler görülebilir.

**Öneriler (öncelik sırası):**

1. `UFW_ADMIN_EXPOSURE=caddy-only` + panellere yalnızca Caddy üzerinden erişim
2. Tailscale ile admin; UFW’de hassas portları kapatma
3. Internal TLS (`step-ca` / Caddy `tls internal`) — v2

## Secrets

- `.env` asla git’e girmez
- `backup.sh` secrets kopyalamaz
- Restic şifreli; offsite için `make backup-pull`

## CrowdSec bouncer

`setup-crowdsec-bouncer.sh` host bouncer dener; olmazsa `sync-crowdsec-ufw.sh` + timer ile CrowdSec kararlarini UFW'ye yansitir.

```bash
sudo systemctl status crowdsec-firewall-bouncer  # host kurulumu varsa
sudo systemctl status pi-gateway-crowdsec-ufw.timer
docker exec crowdsec cscli decisions list
```

## Cloudflare Tunnel

Token varsa dış erişim açılır. Yalnızca gerekli hostname’leri expose edin; HTTPS termination Cloudflare tarafında olmalı.

## Kontrol listesi

- [ ] Tüm varsayılan şifreler değiştirildi
- [ ] Telegram bildirimleri test edildi
- [ ] `make backup-pull` haftalık cron (Mac)
- [ ] Syncthing GUI şifresi set
- [ ] Tailscale 2FA (hesap tarafı)

## Public GitHub hazırlığı

Repo public yapmadan önce:

1. `make validate` — `validate-public-repo.sh` secret/PII taraması
2. `.env` asla commit edilmedi — `git log -- .env` boş olmalı
3. Chat veya logda görünen gerçek token/şifreleri **rotate** et (Telegram, Tailscale, servis şifreleri)
4. `config/tailscale/acl.hujson` ve `host/dhcpcd/pi-gateway.conf` yalnızca Pi'de render — git'te yok
5. `TAILSCALE_ACL_OWNER` `.env`'de gerçek Tailscale e-postası (tracked değil)
6. Watchtower açıksa `WATCHTOWER_NOTIFICATION_URL` token içerir — URL loglara düşebilir; gerekmedikçe kapalı tut

Public sonrası: güvenlik sorunları için [.github/SECURITY.md](../.github/SECURITY.md) prosedürünü izle; acil durumda repo private + secret rotation.
