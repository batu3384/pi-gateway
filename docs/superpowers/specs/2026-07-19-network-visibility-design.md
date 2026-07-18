# Ağ Görünürlüğü (NetAlertX) — Tasarım Spesifikasyonu

**Tarih:** 2026-07-19  
**Durum:** Onay bekliyor  
**Kapsam:** Pi Gateway Faz 4 — LAN cihaz envanteri ve yeni cihaz uyarıları

---

## 1. Problem ve hedef

### Mevcut durum

Pi Gateway şu katmanları iyi kapsıyor:

| Katman | Araç | Ne izler? |
|--------|------|-----------|
| Servis sağlığı | Uptime Kuma | `dns.home`, `n8n.home` ayakta mı? |
| DNS / filtre | AdGuard | Sorgular, engeller; kısmi istemci listesi |
| Altyapı | health-check timer | DNS stack, disk, SD |
| Bildirim | Telegram + n8n | Kuma, Forgejo, sabah özeti |

**Eksik:** Ağa kim bağlandı? Bilinmeyen MAC/IP görüldü mü? Hangi cihaz ne zaman offline oldu?

### Hedef

- Ev LAN'ındaki cihazların **sürekli envanteri** (IP, MAC, isim, son görülme)
- **Yeni / bilinmeyen cihaz** bağlandığında Telegram bildirimi
- Mevcut güvenlik modeline uyum: **Caddy + TLS + basic auth**, UFW `caddy-only`
- Mevcut bildirim hattını **yeniden kullanma** (n8n → Telegram), paralel kanal açmama
- Pi 4 hybrid depolama: veri **SSD** üzerinde

### Başarı kriterleri

1. `https://devices.home` paneli Caddy auth ile erişilebilir
2. İlk tarama sonrası LAN cihazları listede görünür
3. Test cihazı (veya simüle MAC) eklendiğinde n8n webhook → Telegram mesajı gelir
4. `make validate` ve smoke test geçer; Kuma'da `devices.home` yeşil
5. NetAlertX UI portu (`20211`) LAN'a doğrudan açık değil

---

## 2. Yaklaşım karşılaştırması

### Seçenek A — NetAlertX (önerilen)

Tam özellikli ağ envanteri; Pi.Alert mirası; homelab için olgun.

| Artı | Eksi |
|------|------|
| ARP + isim çözümleme + workflow | `network_mode: host` veya ham soket yetkisi |
| n8n webhook, Telegram (Apprise) | GPL-3.0 lisans |
| SSD'de config/db | ~150–300 MB RAM, periyodik tarama CPU |
| Zengin UI, CSV export | Docker compose yakın zamanda değişti |

### Seçenek B — Minimal `arp-scan` + `notify.sh`

Cron ile ARP taraması, bilinen MAC listesi ile diff, Telegram.

| Artı | Eksi |
|------|------|
| ~50 satır bash, sıfır yeni UI | Envanter UI yok, isim çözümleme zayıf |
| Host'ta tek komut | Workflow, presence, rapor yok |
| Düşük kaynak | Uzun vadede bakım yükü sende |

### Seçenek C — Yalnızca AdGuard istemci API

AdGuard'ın gördüğü DNS istemcilerini poll et.

| Artı | Eksi |
|------|------|
| Ek container yok | DNS kullanmayan cihazlar görünmez |
| Zaten kurulu | “Shadow device” tespiti yetersiz |

### Karar

**Seçenek A (NetAlertX)** — kullanıcı isteği ve profesyonel envanter ihtiyacı ile uyumlu. B ve C yalnızca “çok hafif MVP” alternatifi olarak dokümante edilir; uygulanmaz.

---

## 3. Mimari

### Yerleşim

```
                    ┌─────────────────────────────────────┐
                    │           Ev LAN (192.168.1.0/24)    │
                    │  Mac, telefon, IoT, router...        │
                    └──────────────┬──────────────────────┘
                                   │ ARP / ICMP
                                   ▼
┌──────────────────────────────────────────────────────────────┐
│ Raspberry Pi 4 (hybrid: SD root + SSD data)                   │
│                                                               │
│  ┌─────────────┐   host network    ┌─────────────────────┐   │
│  │  NetAlertX  │◄── ARP scan ─────►│ eth0 (PI_INTERFACE) │   │
│  │  :20211     │   127.0.0.1 only  └─────────────────────┘   │
│  └──────┬──────┘                                              │
│         │ webhook (docker bridge)                             │
│         ▼                                                     │
│  ┌─────────────┐     ┌──────────┐     ┌─────────────────┐    │
│  │    n8n      │────►│ Telegram │     │  Uptime Kuma    │    │
│  └─────────────┘     └──────────┘     │  devices.home   │    │
│                                        └─────────────────┘    │
│  ┌─────────────┐                                              │
│  │   Caddy     │  https://devices.home → 127.0.0.1:20211      │
│  │   :443      │  (extra_hosts / PI_STATIC_IP)                 │
│  └─────────────┘                                              │
│                                                               │
│  SSD: data/netalertx/{config,db}                              │
└──────────────────────────────────────────────────────────────┘
```

### NetAlertX ağ modu

Resmi dokümantasyon ARP taraması için **`network_mode: host`** önerir.

**Pi Gateway uyumu:**

- Container `network_mode: host`
- `LISTEN_ADDR=127.0.0.1`, `PORT=20211` — UI yalnızca localhost
- Caddy `devices.__LAN_DOMAIN__` → `__PI_STATIC_IP__:20211` (AdGuard/DNS ile aynı kalıp)
- UFW: 20211 **açılmaz** (caddy-only korunur)

### Keşif stratejisi (`NETWORK_MODE` aware)

| Mod | Birincil keşif | İkincil |
|-----|----------------|---------|
| `router-dns` (varsayılan) | `ARPSCAN` — `SCAN_SUBNETS` = `LAN_SUBNET_CIDR` + `PI_INTERFACE` | `DIGSCAN` / `NSLOOKUP` isim |
| `adguard-dhcp` | `ARPSCAN` + ileride `DHCPLSS` (AdGuard lease dosyası) | AdGuard DNS istemcileri (manuel/REST) |

İlk sürüm: **ARPSCAN yeterli**; AdGuard importer Faz 4.1 backlog.

### Bildirim stratejisi

**Tek hat:** NetAlertX `WEBHOOK` plugin → n8n `netalert-device-alert` → Telegram.

- NetAlertX içinde doğrudan Telegram **kapalı** (çift yapılandırma önlenir)
- `WEBMON` plugin **devre dışı** (website izleme Kuma'da)
- Cooldown: NetAlertX notification settings + mevcut `NOTIFY_COOLDOWN_SEC` benzeri n8n filtre (gerekirse)

### Kuma ile ilişki

| Monitor | Ne ölçer? |
|---------|-----------|
| `devices.home` | Caddy + NetAlertX UI (401/200) |
| `Dozzle` | Container logları (değişmez) |
| NetAlertX içi | Cihaz presence (ayrı domain) |

Kuma “servis ayakta mı”; NetAlertX “ağda kim var” — **çakışma yok**.

---

## 4. Bileşenler ve dosya etkisi

### Yeni / değişecek parçalar

| Bileşen | Sorumluluk |
|---------|------------|
| `compose/docker-compose.yml` | `netalertx` servisi, profile `netalert` |
| `.env.example` / `docs/ENV.md` | `ENABLE_NETALERTX`, port, subnet |
| `config/caddy/Caddyfile.*.template` | `devices.home` vhost |
| `config/homepage/services.yaml.template` | Panel linki |
| `config/n8n/netalert-device-alert.workflow.json` | Webhook → Telegram |
| `scripts/pi/setup-netalertx.sh` | İlk config, plugin, SCAN_SUBNETS |
| `scripts/pi/setup-n8n-netalert.sh` | Workflow import (mevcut kalıp) |
| `scripts/pi/post-deploy.sh` | Kurulum adımları |
| `scripts/pi/smoke-test.sh` | `devices.home` kontrolü |
| `scripts/pi/setup-uptime-kuma.sh` | `devices.home` monitor |
| `scripts/lib/notify.sh` | (opsiyonel) `panel_url devices` |
| `scripts/pi/telegram-menu.sh` | Devices butonu |
| `docs/ARCHITECTURE.md` | Faz 4 satırı |
| `docs/OPERATIONS.md` | Panel tablosu, bildirim kaynağı |
| `docs/FAZ4.md` | Kullanım rehberi (yeni) |

### Ortam değişkenleri

```bash
ENABLE_NETALERTX=true
NETALERTX_PORT=20211
# Boşsa discover-remote LAN_SUBNET_CIDR + PI_INTERFACE ile dolar
NETALERTX_SCAN_SUBNETS=
# n8n webhook path secret (N8N_WEBHOOK_SECRET ile aynı veya ayrı)
NETALERTX_WEBHOOK_PATH=netalert-device-alert
```

### Depolama

```
/mnt/ssd/pi-gateway-data/netalertx/
├── config/    # app.conf, plugin ayarları
└── db/        # SQLite envanter
```

Restic yedeğine `data/netalertx` dahil edilir (mevcut backup scriptleri kontrol).

---

## 5. Güvenlik

| Risk | Azaltma |
|------|---------|
| Host network container | Yalnızca localhost bind; profil opsiyonel (`ENABLE_NETALERTX=false`) |
| ARP taraması gürültüsü | Tarama aralığı ≥ 15 dk; gece modu (NetAlertX schedule) |
| GPL-3.0 | Özel homelab kullanımı OK; türev dağıtımında lisans metni |
| Yanlış “yeni cihaz” alarmı | İlk kurulumda “maintenance” ile toplu onay; workflow ile MAC whitelist |
| Panel erişimi | Caddy basic auth zorunlu; Tailscale ACL önerisi devam |

---

## 6. Kaynak bütçesi (Pi 4)

| Metrik | Tahmin |
|--------|--------|
| RAM | +150–250 MB (idle), tarama anında +100 MB |
| CPU | İlk tarama 5–10 dk yoğun; sonra düşük |
| Disk (SSD) | ~50–200 MB db büyümesi / yıl |
| Ağ | ARP burst / 15 dk; ev LAN için ihmal edilebilir |

Mevcut 13 container + hybrid SSD ile **uyumlu**; `ENABLE_DOCKER_SSD=false` korunur.

---

## 7. Test planı

1. `make render && make validate`
2. `make deploy-fast` — post-deploy NetAlertX + n8n workflow
3. Pi smoke: `devices.home` auth, NetAlertX health
4. Fonksiyonel: yeni cihaz simülasyonu veya misafir telefon → Telegram
5. Regresyon: DNS stack, Syncthing, mevcut Kuma monitörleri yeşil

---

## 8. Rollout fazları

| Faz | İçerik |
|-----|--------|
| **4.0** | NetAlertX container, Caddy, Homepage, smoke, Kuma monitor |
| **4.1** | n8n webhook + Telegram şablonu, telegram-menu |
| **4.2** | AdGuard DHCP lease importer (`adguard-dhcp` modu) |
| **4.3** | Homepage widget / presence özeti (opsiyonel) |

---

## 9. Açık kararlar (onay için)

1. **Panel hostname:** `devices.home` (önerilen) — alternatif `lan.home`
2. **Varsayılan:** `ENABLE_NETALERTX=true` (onaylandı)
3. **Bildirimler:** Yalnızca “yeni cihaz” mı, offline/presence de mi? → Öneri: **yeni cihaz + bilinmeyen**; offline ayrı workflow (Faz 4.1)

---

## 10. Referanslar

- [NetAlertX GitHub](https://github.com/netalertx/NetAlertX)
- [Docker kurulum](https://docs.netalertx.com/DOCKER_INSTALLATION)
- [Plugins](https://docs.netalertx.com/PLUGINS)
- [n8n Webhook](https://docs.netalertx.com/WEBHOOK_N8N)
