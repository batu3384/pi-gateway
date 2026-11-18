---
name: pi-gateway-ops
description: "Pi Gateway ev sunucusu ops. Sistem/stack/durum/yedek/DNS/container sorularında kullan. Forgejo/Syncthing YOK."
version: 3.0.0
author: Pi Gateway
license: MIT
platforms: [linux]
metadata:
  hermes:
    tags: [Pi-Gateway, ops, health, docker, restic]
---
# Pi Gateway ops

Home server: Raspberry Pi 4B 4GB (Hibrit: OS microSD, veri + Docker `/mnt/ssd`). Repo: `~/pi-gateway`.

## Stack (güncel SSOT)

**Aktif:** AdGuard Home → Unbound (DoT `:853`), Caddy (`*.home` TLS), Glance (`gateway.home`), Gatus (`status.home`),
VictoriaMetrics (`:9090`) + Grafana (`grafana.home`) + node-exporter (`:9100`), Dozzle (`logs.home`),
NetAlertX (`devices.home`), CrowdSec + UFW, Restic, Tailscale, Raspberry Pi Connect, Hermes, deprem + İBB HKI zamanlayıcıları.

**Emekli / Yok:** Homepage, Uptime Kuma, Prometheus, n8n (`ENABLE_N8N=false`), Forgejo, Syncthing, Alertmanager, Immich, Nextcloud, Home Assistant.

## Script — iki kopya

- Repo: `__REMOTE_DIR__` (`~/pi-gateway`)
- Systemd: `/usr/local/lib/pi-gateway/` — unit’ler buradan çalışır.

Senkron gerekirse:
```bash
sudo bash __REMOTE_DIR__/scripts/pi/install-privileged-scripts.sh
```

## Hızlı durum

```bash
uptime; free -h; df -hP / /mnt/ssd 2>/dev/null; vcgencmd measure_temp 2>/dev/null
systemctl --failed --no-pager
docker ps --format "table {{.Names}}\t{{.Status}}"
REMOTE_DIR=__REMOTE_DIR__ bash __REMOTE_DIR__/scripts/pi/health-check.sh
```

Cevap kısa ve net olsun: temel metrikler, konteyner durumu, varsa failed unit, disk/RAM özeti.

## Yedek

- Timer: `pi-gateway-backup.timer` → `backup.sh` → `restic-backup.sh` (`/mnt/ssd/pi-gateway-data/backups/restic`).
- Başarı: son `restic snapshot` + `~/pi-gateway/backups/<stamp>/` (secret içermez). Rutin gece yedeği sessizdir; yalnız hata olursa bildirim gider.

## Bilinen notlar

- AdGuard yapılandırma izinleri: `fix-config-perms.sh` sahipliği korur.
- SSH key-only (`00-pi-gateway-ssh.conf`), TCP BBR + `fq` (`99-pi-gateway-net.conf`), `eth0` ↔ `wlan0` otomatik failover.
- Modem DHCP DNS1 Pi’yi (`PI_STATIC_IP`) gösterir; sabit IPv6 DNS için `radvd` ULA RDNSS devrededir.

## Panel & Hızlı Komutlar

`/menu` → sabit durum kartını ve panel butonlarını yeniler (`hermes-menu.sh`).
`/dns`, `/ssd`, `/backup`, `/recover` → doğrudan ilgili operasyon özetini gönderir.
