---
name: pi-gateway-ops
description: "Pi Gateway ev sunucusu ops. Sistem/stack/durum/yedek/DNS/container sorularında kullan. Forgejo/Syncthing YOK."
version: 2.0.0
author: Pi Gateway
license: MIT
platforms: [linux]
metadata:
  hermes:
    tags: [Pi-Gateway, ops, health, docker, restic]
---
# Pi Gateway ops

Home server: Raspberry Pi 4B 4GB. Repo: `~/pi-gateway`.

## Stack (doğru)

**Var:** AdGuard → Unbound, Caddy, Homepage, Uptime Kuma, Dozzle, n8n (executeCommand+SSH kapalı),
NetAlertX, CrowdSec, Prometheus+Grafana (scrape), node-exporter, restic, Tailscale, Hermes, quake timer.

**Yok:** Forgejo, Syncthing, Alertmanager, Immich, Nextcloud, Home Assistant.

## Script — iki kopya

- Repo: `/home/batu/pi-gateway/` (veya `__REMOTE_DIR__`)
- Systemd: `/usr/local/lib/pi-gateway/` — unit’ler buradan çalışır; deploy sonrası geride kalabilir.

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

Cevap kısa: key metrics, container sayısı, failed unit, disk/inode/RAM. Onarım geçmişi dökme.

## Yedek

- Timer: `pi-gateway-backup.timer` → `backup.sh` → restic (SSD).
- Başarı: `restic snapshot` satırı + `~/pi-gateway/backups/<stamp>/` (secret yok).
- Offsite skip normal: `RESTIC_OFFSITE_ENABLED=false`.

## Bilinen tuzaklar

- AdGuard UI edit → yaml `root:0600` → backup `cp` kırılır: `chown`/`fix-config-perms.sh`.
- `reset-failed` yedek/SSD oneshot fail’ini gizlemesin (`reset-gateway-units.sh` dar liste).
- SSH key-only (`00-pi-gateway-ssh.conf`). Script `+x` kaybı → `chmod +x`.
- LG TV DNS bypass (modem DNS2) — Pi tavanı; “tüm ev kilidi” iddia etme.

## Panel

`/menu` → ayrı skill (`hermes-menu.sh`). Bu skill sohbet/ops içindir.
