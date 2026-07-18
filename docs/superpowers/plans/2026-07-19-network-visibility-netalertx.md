# NetAlertX Ağ Görünürlüğü — Uygulama Planı

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Pi Gateway'e NetAlertX tabanlı LAN cihaz envanteri ve yeni-cihaz Telegram uyarıları eklemek; mevcut Caddy/n8n/Kuma kalıplarına uyumlu.

**Architecture:** NetAlertX `host` network + localhost UI; Caddy `devices.home` reverse proxy; WEBHOOK → n8n → Telegram; veri SSD `data/netalertx/`.

**Tech Stack:** NetAlertX (`ghcr.io/netalertx/netalertx`), Docker Compose profile `netalert`, Caddy TLS, n8n 2.x, uptime-kuma-api2.

**Spec:** `docs/superpowers/specs/2026-07-19-network-visibility-design.md`

## Global Constraints

- Hybrid depolama: `data/netalertx` → SSD symlink altında
- UFW `caddy-only`: NetAlertX portu LAN'a açılmaz
- Bildirim: n8n webhook hattı; NetAlertX doğrudan Telegram kullanmaz
- `ENABLE_NETALERTX=false` varsayılan (`.env.example`)
- Panel hostname: `devices.home`
- Türkçe log/mesaj metinleri (`notify.sh`, n8n workflow)
- `make validate` ve smoke test 36+ kontrol geçmeli

---

## Dosya haritası

| Dosya | Aksiyon |
|-------|---------|
| `compose/docker-compose.yml` | `netalertx` servisi |
| `.env.example`, `docs/ENV.md` | Yeni değişkenler |
| `config/caddy/Caddyfile.template` | `devices.home` |
| `config/caddy/Caddyfile.tls.template` | `devices.home` |
| `config/homepage/services.yaml.template` | Link |
| `config/n8n/netalert-device-alert.workflow.json` | Yeni workflow |
| `scripts/pi/setup-netalertx.sh` | Kurulum |
| `scripts/pi/setup-n8n-netalert.sh` | n8n import |
| `scripts/pi/post-deploy.sh` | Adımlar |
| `scripts/pi/setup-uptime-kuma.sh` | Monitor |
| `scripts/pi/smoke-test.sh` | Kontrol |
| `scripts/pi/telegram-menu.sh` | Buton |
| `scripts/lib/compose-profiles.sh` | Profile |
| `scripts/mac/deploy.sh` | Profile |
| `scripts/mac/validate-stack-health.sh` | Kontrat |
| `scripts/pi/setup-ssd-data.sh` | Dizin |
| `docs/ARCHITECTURE.md`, `docs/OPERATIONS.md`, `docs/FAZ4.md` | Dokümantasyon |

---

### Task 1: Compose servisi ve env

- [ ] **1.1** `compose/docker-compose.yml` — `netalertx` ekle:
  ```yaml
  netalertx:
    image: ghcr.io/netalertx/netalertx:latest
    container_name: netalertx
    restart: unless-stopped
    profiles: ["netalert"]
    network_mode: host
    labels:
      autoheal: "true"
    environment:
      PORT: ${NETALERTX_PORT:-20211}
      LISTEN_ADDR: 127.0.0.1
      PUID: ${NETALERTX_UID:-20211}
      PGID: ${NETALERTX_GID:-20211}
      APP_CONF_OVERRIDE: ${NETALERTX_APP_CONF_OVERRIDE:-}
    volumes:
      - ../data/netalertx:/data
      - /etc/localtime:/etc/localtime:ro
    tmpfs:
      - /tmp:uid=20211,gid=20211,mode=1700
  ```
- [ ] **1.2** `.env.example` — `ENABLE_NETALERTX=false`, `NETALERTX_PORT=20211`, `NETALERTX_SCAN_SUBNETS=`
- [ ] **1.3** `scripts/lib/compose-profiles.sh` + `scripts/mac/deploy.sh` — `--profile netalert` when enabled
- [ ] **1.4** `scripts/pi/setup-ssd-data.sh` — `netalertx` dizini
- [ ] **1.5** Commit: `feat(netalert): compose servisi ve env`

---

### Task 2: Caddy ve Homepage

- [ ] **2.1** `config/caddy/Caddyfile.tls.template` ve `.template` — ekle:
  ```
  devices.__LAN_DOMAIN__ {
    tls ...
    __CADDY_BASIC_AUTH__
    reverse_proxy __PI_STATIC_IP__:__NETALERTX_PORT__
  }
  ```
- [ ] **2.2** `scripts/mac/render-config.sh` — `NETALERTX_PORT` export
- [ ] **2.3** `config/homepage/services.yaml.template` — NetAlertX / Devices satırı
- [ ] **2.4** `make render && make validate`
- [ ] **2.5** Commit: `feat(netalert): Caddy devices.home ve homepage`

---

### Task 3: setup-netalertx.sh

- [ ] **3.1** Yeni `scripts/pi/setup-netalertx.sh`:
  - `ENABLE_NETALERTX` guard
  - Container healthy bekle (`http://127.0.0.1:${PORT}`)
  - `SCAN_SUBNETS` = `NETALERTX_SCAN_SUBNETS` veya `"${LAN_SUBNET_CIDR} --interface=${PI_INTERFACE}"`
  - REST API veya `APP_CONF_OVERRIDE` ile plugin listesi:
    - `ARPSCAN`, `DIGSCAN`, `WEBHOOK`, `NEWDEV`, `NTFPRCS`
    - `WEBMON` disabled
  - İlk kurulum notu logla (5–10 dk tarama)
- [ ] **3.2** `post-deploy.sh` — `run_step_optional` veya `critical`
- [ ] **3.3** Manuel Pi test: container up, localhost 20211
- [ ] **3.4** Commit: `feat(netalert): otomatik kurulum scripti`

---

### Task 4: n8n webhook workflow

- [ ] **4.1** `config/n8n/netalert-device-alert.workflow.json` — webhook path `netalert-device-alert-__N8N_WEBHOOK_SECRET__`
- [ ] **4.2** Code node: NetAlertX JSON → Türkçe mesaj (`yeni cihaz`, MAC, IP, isim)
- [ ] **4.3** `scripts/pi/setup-n8n-netalert.sh` — `setup-n8n-workflows.sh` kalıbı
- [ ] **4.4** `setup-netalertx.sh` sonunda NetAlertX WEBHOOK URL yaz (UI veya config API)
- [ ] **4.5** `post-deploy.sh` — n8n adımı
- [ ] **4.6** Test: curl webhook → Telegram
- [ ] **4.7** Commit: `feat(netalert): n8n webhook ve Telegram`

---

### Task 5: Monitoring ve smoke

- [ ] **5.1** `setup-uptime-kuma.sh` — monitor `devices.{lan}` → `https://devices.{lan}`, `accepted_statuscodes` mevcut `ok` listesi
- [ ] **5.2** `smoke-test.sh` — `caddy-devices-auth-deny/ok` (diğer paneller gibi)
- [ ] **5.3** `health-check.sh` — opsiyonel `netalertx` container check
- [ ] **5.4** `validate-stack-health.sh` — host network, localhost bind, profile kontratı
- [ ] **5.5** `make validate` + Pi smoke 36+
- [ ] **5.6** Commit: `feat(netalert): kuma monitor ve smoke test`

---

### Task 6: Telegram menü ve dokümantasyon

- [ ] **6.1** `telegram-menu.sh` — "Ağ Cihazları" butonu → `devices.home`
- [ ] **6.2** `docs/FAZ4.md` — kurulum, ilk onay, bakım
- [ ] **6.3** `docs/ARCHITECTURE.md` — Faz 4 satırı
- [ ] **6.4** `docs/OPERATIONS.md` — panel tablosu, bildirim kaynağı
- [ ] **6.5** `docs/ENV.md` — değişkenler
- [ ] **6.6** Commit: `docs(netalert): Faz 4 rehberi`

---

### Task 7: Üretim doğrulama

- [ ] **7.1** Mac `.env`: `ENABLE_NETALERTX=true`
- [ ] **7.2** `make deploy-fast`
- [ ] **7.3** `https://devices.home` — Caddy auth → NetAlertX UI
- [ ] **7.4** Envanterde LAN cihazları görünür
- [ ] **7.5** Kuma `devices.home` yeşil
- [ ] **7.6** (Opsiyonel) misafir cihaz testi → Telegram

---

## Rollback

```bash
# .env
ENABLE_NETALERTX=false
# Pi
cd ~/pi-gateway/compose && docker compose --profile netalert stop netalertx
```

Veri `data/netalertx/` korunur; yeniden açınca envanter devam eder.

---

## Backlog (Faz 4.1+)

- AdGuard DHCP lease importer (`NETWORK_MODE=adguard-dhcp`)
- NetAlertX device → Homepage widget
- MAC whitelist dosyası (`config/netalertx/known-devices.csv`)
- Restic backup path doğrulama
