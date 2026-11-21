---
name: pi-gateway-ops
description: "Pi Gateway ev sunucusu ops. Sistem/stack/durum/yedek/DNS/container sorularında kullan. Forgejo/Syncthing YOK."
version: 3.0.0
author: Pi Gateway
license: MIT
platforms: [linux]
metadata:
  openbot:
    tags: [Pi-Gateway, ops, health, docker, restic]
---
# Pi Gateway ops

Home server: Raspberry Pi 4B 4GB (Hibrit: OS microSD, veri + Docker `/mnt/ssd`). Repo: `~/pi-gateway`.

## Stack (güncel SSOT)

**Aktif:** AdGuard Home → Unbound (DoT `:853`), Caddy (`*.home` TLS), Glance (`gateway.home`), Gatus (`status.home`),
VictoriaMetrics (`victoriametrics:8428`, dahili bridge) + Grafana (`grafana.home`) + node-exporter (`:9100`), Dozzle (`logs.home`),
NetAlertX (`devices.home`), CrowdSec (`DOCKER-USER` + journald) + UFW, Restic, Tailscale, OpenBot Jarvis, deprem + İBB HKI zamanlayıcıları.

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
REMOTE_DIR=__REMOTE_DIR__ bash __REMOTE_DIR__/scripts/pi/jarvis-snapshot.sh
REMOTE_DIR=__REMOTE_DIR__ bash __REMOTE_DIR__/scripts/pi/health-check.sh
```

Cevap kısa ve net olsun: temel metrikler, konteyner durumu, varsa failed unit, disk/RAM özeti.

## Yedek

- Timer: `pi-gateway-backup.timer` → `backup.sh` → `restic-backup.sh` (`/mnt/ssd/pi-gateway-data/backups/restic`).
- Başarı: son `restic snapshot` + `~/pi-gateway/backups/<stamp>/` (secret içermez). Rutin gece yedeği sessizdir; yalnız hata olursa bildirim gider.

## Bilinen notlar

- AdGuard yapılandırma izinleri: `fix-config-perms.sh` sahipliği korur.
- SSH key-only (`00-pi-gateway-ssh.conf`), TCP BBR + `fq` (`99-pi-gateway.conf`), JMicron `read_ahead_kb=0` (`99-pi-gateway-jmicron.rules`), `eth0` ↔ `wlan0` otomatik failover.
- Modem DHCP DNS1 Pi’yi (`PI_STATIC_IP`) gösterir; sabit IPv6 DNS için `radvd` ULA RDNSS devrededir.

## Panel & Hızlı Komutlar

`/menu` veya “menü” → `REMOTE_DIR=__REMOTE_DIR__ bash __REMOTE_DIR__/scripts/pi/gateway-status.sh` (stdout’u aynen yaz).
`/dns`, `/ssd`, `/backup`, `/recover` → `telegram-ops.sh --stdout` (ayrı skill). Çıktıyı doğrudan sohbete yaz.
