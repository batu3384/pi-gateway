# Environment Variables (.env)

## Required (before deploy)

| Variable | Description |
|----------|-------------|
| `PI_HOST` / `PI_STATIC_IP` | Pi LAN address (service bind, DNS) |
| `PI_DEPLOY_HOST` | Optional SSH/deploy host (e.g. Tailscale `100.x` when LAN unreachable) |
| `AGH_ADMIN_PASSWORD` | AdGuard admin (≥12 characters) |
| `LAN_GATEWAY`, `LAN_SUBNET_CIDR`, `PI_IPV6_ULA` | Filled by `discover-remote.sh` |

## DNS / AdGuard

| Variable | Default |
|----------|---------|
| `ADGUARD_BOOT_WAIT_SEC` | 180 |
| `ADGUARD_MIN_FILTER_RULES` | 100000 |
| `ADGUARD_MIN_REWRITES` | 8 |
| `ADGUARD_BLOCKED_TTL` | 60 |
| `ADGUARD_FILTER_PREFLIGHT` / `ADGUARD_FILTER_PREFLIGHT_TIMEOUT_SEC` | `true` / `20`; HTTPS, izinli host, redirect ve filter syntax kontrolü |
| `ADGUARD_FILTER_FORCE_REFRESH` | `false`; `true` yalnız kontrollü manuel yenileme için |
| `ADGUARD_FILTER_SCHEDULED_SLA_SEC` | `93600` (26 saat); doğrulanmış scheduled apply yaş sınırı |
| `ADGUARD_FILTER_MAX_SOURCE_BYTES` | `134217728` (128 MiB); kaynak akış boyut tavanı |
| `ADGUARD_FILTER_POLL_SEC` / `ADGUARD_FILTER_POLL_INTERVAL_SEC` | `180` / `5`; refresh sonrası governance poll (AGH liste indirme süresi) |
| `ADGUARD_FILTER_LOCK_WAIT_SEC` | `120`; `apply-adguard-filters` flock bekleme |
| `ADGUARD_FILTER_API_READY_WAIT_SEC` | `120`; stack restart sonrası AGH filtering API readiness bekleme |
| `ADGUARD_FILTER_STATE_PATH` | Boşsa `/var/lib/pi-gateway/adguard-filter-state.json` |
| `ADGUARD_FILTER_SOURCE_CACHE_PATH` | Boşsa `/var/lib/pi-gateway/adguard-filter-source-cache.json` (ETag/If-Modified-Since) |
| `ADGUARD_FILTER_PROFILE` | `balanced` (TIF Medium). `balanced-core` = Pro++ + TIF Medium + DoH (3 liste, düşük RAM). `aggressive` = TIF Full + CNAME original trackers; AGH ≥2GB RAM. Fake **and** Popup Hosts not stacked (inside Pro++). TIF Full: `apply-adguard-filters` WARNs if MemAvailable <400MiB — effective profile `balanced` olur ve state bunu belirtir. See `docs/DNS-BLOCKING.md`. |
| `config/adguard/filter-lists.json` `budgets` | Profil başına toplam kural üst sınırı; upstream `@latest` büyümesi bu sınırı aşarsa apply başarısız olur ve stale listeler kaldırılmaz |
| `ROUTER_DNS_SECONDARY` | Yalnız `MAC_DNS_GATEWAY_FALLBACK=true` iken. **Bos** veya `LAN_GATEWAY`. Public resolver WAN `:53` drop ile ölür. |
| `MAC_DNS_GATEWAY_FALLBACK` | `false` (varsayılan): `make mac-dns` modem `.1` eklemez; **yalnız LAN IP** olan Ethernet/Wi-Fi. Hotspot'a Pi+ULA yazmaz (`make mac-dns-clear`). `true`: Pi down yedek; modem LAN `:53` reklam kaçırır. |
| `DHCP_RANGE_START` / `DHCP_RANGE_END` / `LAN_SUBNET_MASK` | Yalnız `NETWORK_MODE=adguard-dhcp`. Örnek: `192.168.1.50`–`200`, `255.255.255.0`. |
| `MODEM_IPV6_DNS_LL` | `fe80::1`. radvd RFC 8106 lifetime 0 (modem RDNSS un-advertise). |
| `MODEM_INVENTORY_ENABLED` | `false` (önerilen: modem credential dosyası hazırlandıktan sonra `true`) |
| `MODEM_URL` | `http://192.168.1.1` |
| `MODEM_ALLOW_HTTP` | `false`; HTTPS desteklemeyen modem için açıkça `true` yapılır, login LAN’da şifreli değildir |
| `MODEM_TLS_CA_FILE` | HTTPS modem sertifikası/CA PEM yolu; boşsa sistem CA store kullanılır |
| `MODEM_TLS_INSECURE` | `false`; yalnız self-signed modem sertifikası için açıkça `true`, authenticity doğrulanmaz |
| `MODEM_INVENTORY_PATH` | Boşsa `${REMOTE_DIR}/data/modem-inventory.json` |
| `MODEM_INVENTORY_STALE_SEC` | `900`; bu süreden eski snapshot IP eşleştirmesinde kullanılmaz |
| `MODEM_INVENTORY_REQUIRED` | `false`; `true` iken (veya inventory enabled iken) snapshot yok/eskiyse strict audit `UNKNOWN` döner |
| `NETALERTX_RECENCY_SEC` | `900`; NetAlertX `devLastConnection` aktiflik kanıtı penceresi |
| `ADGUARD_AUDIT_QUERY_RECENCY_SEC` | `NETALERTX_RECENCY_SEC` ile aynı varsayılan; eski AdGuard querylog kayıtları aktif cihaz kanıtı sayılmaz |
| `VIDEO_QUERY_RECENCY_SEC` | `300`; video diagnostik query log için son kanıt penceresi |
| `VIDEO_CLIENT_MAX_LOSS_PERCENT` | `20`; hedef cihaz ICMP packet loss üstünde `WARN` üretir |
| `VIDEO_CLIENT_MAX_JITTER_MS` | `30`; hedef cihaz ping RTT mdev üstünde `WARN` üretir |
| `VIDEO_HTTP_PROBE_URL` | `https://www.youtube.com/generate_204`; Pi kaynaklı HTTPS WAN kanıtı |
| `VIDEO_HTTP_PROBE_TIMEOUT_SEC` | `8`; HTTPS probe timeout değeri, 1–60 saniye |
| `NETALERTX_GID` | `1000` örneği; NetAlertX container PGID host kullanıcı grubuyla eşleşmeli |
| `ADGUARD_COVERAGE_AUDIT_ENABLED` | `true`; health timer DNS kapsam kanıtını warn modunda yeniler |
| `ADGUARD_DNS_COVERAGE_STATE_PATH` | `/var/lib/pi-gateway/dns-coverage-state.json`; son kapsam kanıtı |
| `ADGUARD_DNS_COVERAGE_STATE_MAX_AGE_SEC` | `600`; eski kapsam kanıtı metric’te `UNKNOWN` olur |

ZTE H3600P credential'ları repo `.env` içine konmaz. `/etc/pi-gateway/modem-inventory.env`
dosyasını root sahipli `0600` oluşturun (`MODEM_USERNAME=...`, `MODEM_PASSWORD=...`);
systemd bunu `LoadCredential` ile servise aktarır. `MODEM_URL=https://...` firmware destekliyorsa
tercih edilir; HTTP yalnız `MODEM_ALLOW_HTTP=true` ile çalışır ve LAN sniffing riski taşır.
Adapter yalnızca GET veri endpoint'leri
ve login/logout çağrısı kullanır; response/session hatasında eski snapshot korunur.
Snapshot cihaz kayıtları `source`, `confidence`, `privacy_mac` ve `last_seen` alanlarını
taşır. NetAlertX ile DNS audit bu aynı snapshot loader'ını kullanır; stale snapshot
isim gösterebilir ama aktiflik/DNS kanıtı olarak kullanılamaz.
Kurulum: `sudo install -d -m 755 /etc/pi-gateway` → `sudoedit
/etc/pi-gateway/modem-inventory.env` → `sudo chown root:root ...` ve `sudo chmod
600 ...`. Sonra `.env` içinde inventory'yi açıp `make modem-inventory` çalıştırın;
ilk doğrulamadan sonra modem parolasını rotate edin.

## Tailscale

| Variable | Description |
|----------|-------------|
| `TAILSCALE_AUTHKEY` | Device join (bootstrap). Admin DNS/ACL için yetmez. |
| `TAILSCALE_ACL_OWNER` | Tailscale login e-posta — ACL template. |
| `TAILSCALE_API_KEY` | `tskey-api-…` ([Keys](https://login.tailscale.com/admin/settings/keys)). `make tailscale-dns` → global NS=Pi `100.x` + Override + ACL publish. Runtime curl config dosyası kullanır; key process argv’ye yazılmaz. |

## Security

| Variable | Description |
|----------|-------------|
| `UNIFIED_LOGIN` | `true` (default): `AGH_ADMIN_*` = Caddy + Dozzle/Kuma/NetAlertX/Grafana |
| `SYNC_SERVICE_PASSWORDS` | `true` (default with unified): deploy sonrasi GUI sifre esitleme |
| `ENABLE_MONITORING` | `true`: Prometheus + Grafana + node-exporter (`grafana.home`) |
| `ENABLE_CANARY_COMPOSE_UPDATE` | `true`: deploy DNS-once, wait, then edge + apps. Bu evde kapatma — Unbound recreate + WAN `:53` drop. |
| `CANARY_DNS_WAIT_SEC` | `10` (`wait_dns_core` sonrası yastık; eski varsayılan 45). `wait-adguard-dns` zaten `MIN_FILTER_RULES` bekler. |
| `UFW_ADMIN_EXPOSURE` | `full` or `caddy-only` |
| `TELEGRAM_BOT_TOKEN` | @BotFather token (notify outbox + panel; Hermes also keeps copy in `~/.hermes/.env`) |
| `TELEGRAM_CHAT_ID` | Notify / panel hedef chat veya numeric user id |
| `HERMES_TELEGRAM_GATEWAY` | `true` = Hermes owns Telegram inbox (`getUpdates`); panel poller off. Allowlist: `TELEGRAM_ALLOWED_USERS` in `~/.hermes/.env` |
| `HERMES_TELEGRAM_STREAMING` | `false`: Telegram `editMessageText` akıtma kapalı (Bot API flood). GLM API stream = `HERMES_STREAMING` |
| `HERMES_TELEGRAM_TOOL_PROGRESS` | `off`: “terminale bakıyorum” bubble yok. Patch YAML’e `false` yazar (`off` string restart döngüsü). CLI `display.tool_progress` ayrı |
| `HERMES_MAX_WEB_SEARCHES` | `6` (19:00/23:00 bülten tavanı; sabah 3 kullanır) |
| `HERMES_MAX_WEB_EXTRACTS` | `8` |
| `HERMES_STALE_TIMEOUT_SEC` | `600`: `providers.zai.stale_timeout_seconds` (model id `glm-5.3` config set YASAK — walker `glm-5`/`3` yazar) |
| Notify state | `/var/lib/pi-gateway/notify` (reboot-safe). Boot: `pi-gateway-boot-notify.service` + `last-alive` |
| `HERMES_COMPRESS_TOKEN_CAP` | `96000`: compact/prune tavanı (GLM-5.3 %50≈500k hiç ateşlenmez). Akşam bülten ~71k sığar; sohbet yine sınırlı |
| `HERMES_SESSION_RESET_MODE` | `both`: Telegram 04:00 + 12s idle reset (cron ayrı). Unutulmuş process 2s sonra kilitlemez (`HERMES_SESSION_BG_MAX_AGE_H`) |
| `CROWDSEC_BOUNCER_KEY` | Written automatically on first setup |

## SSD / storage

| Variable | Default | Description |
|----------|---------|-------------|
| `STORAGE_TYPE` | `hybrid` | **Production:** SD root + SSD data (`/mnt/ssd`). `ssd-data` alias. |
| `DNS_DEGRADED_ON_SSD_LOSS` | `true` | **Recommended.** On SSD loss, Unbound+AdGuard on SD (core-dns). n8n stay down. |
| `STORAGE_FALLBACK_SD` | `false` | Back-compat: if `true`, enables same DNS degraded path. Full app stack still requires SSD. |
| `SSD_PROBE_TIMEOUT_SEC` | `3` | Write-probe timeout for stale/hung `/mnt/ssd` |
| `SSD_USB_RESET_MAX` | `3` | Soft-reset attempts per window (JMicron `152d:0583`) |
| `SSD_USB_RESET_WINDOW_SEC` | `900` | Soft-reset rate-limit window |
| `SSD_USB_HOST_PORT` | `0` | `0` = hatirlanan + USB3 once; `>0` = once bu port numarasi |
| `SSD_USB_PORT_SCAN_MAX` | `8` | Hatirlanan porttan sonra ayni tick'te kac ekstra USB3 port |
| `SSD_USB_PORT_FORGET_FAILS` | `2` | Bus dropout + bu kadar basarisiz tarama → hatirlanan port sil |
| `SSD_USB_PORT_ROTATE` | `true` | Hatirlanan port yokken USB3 adaylarini tick'te kaydir |
| `SSD_USB_CYCLE_ON_HANG` | `true` | USB enumerate olsa da I/O oluyse port cycle |
| `SSD_USB_STORAGE_REBIND` | `true` | Port power oncesi usb-storage unbind/bind |
| `SSD_USB_XHCI_REBIND` | `false` | Force xHCI PCI rebind (all USB3 collateral) |
| `SSD_USB_XHCI_AUTO_ON_DROPOUT` | `true` | Bus dropout: xhci without explicit `SSD_USB_XHCI_REBIND` |
| `SSD_USB_XHCI_RESET_MAX` | `2` | xHCI rebind attempts per window (separate from port cycle) |
| `SSD_USB_XHCI_RESET_WINDOW_SEC` | `900` | xHCI rate-limit window |
| `SSD_HOTPLUG_DEBOUNCE_SEC` | `30` | Debounce after SSD restore |
| `SSD_USB_RESET_REBOOT` | `false` | If `true`, reboot after reset budget exhausted (last resort) |
| `SSD_USB_AUTHORIZED_RESET` | `false` | If `true`, USB `authorized` 0→1 cycle (risky on JMS583) |
| `ENABLE_DOCKER_SSD` | `false` | `true`: Docker `data-root` on `/mnt/ssd/docker`; degraded → SD fallback |
| `DOCKER_SSD_ROOT` | `/mnt/ssd/docker` | Docker data-root when `ENABLE_DOCKER_SSD=true` |
| `CONTAINERD_ON_SSD` | `false` | `true`: move containerd `root` to `CONTAINERD_SSD_ROOT` (experimental; JMicron USB risk) |
| `CONTAINERD_SSD_ROOT` | `/mnt/ssd/containerd` | containerd root when `CONTAINERD_ON_SSD=true` |
| `STACK_RECOVER_COOLDOWN_SEC` | `180` | Auto-recover wait after compose up |
| `STACK_BOOT_GRACE_SEC` | `120` | Post-boot recover delay |

Experimental `ssd-root`: `docs/SSD-ROOT.md` + `scripts/mac/migrate-sd-boot-ssd-root.sh`

## Backup

| Variable | Description |
|----------|-------------|
| `ENABLE_RESTIC` | true/false |
| `POST_DEPLOY_RESTIC` | `false`: post-deploy tam yedek atlar (timer). Repo boşsa yine ilk snapshot. `true` = her deploy yedekler. |
| `RESTIC_PASSWORD` | Repo password |
| `RESTIC_REPOSITORY` | Path on SSD (not offsite by itself) |
| `MAC_BACKUP_DEST` | Mac `backup-pull` destination |
| `OFFSITE_BACKUP_MAX_AGE_DAYS` | Default `7`; `0` disables age check |
| `BACKUP_DRILL_MAX_AGE_DAYS` | Default `30`; restore drill SLA (`make backup-restore-drill`); `0` off |
| `WEAK_BACKUP_OK` | `yes` = allow stale offsite in doctor |
| `RESTIC_OFFSITE_ENABLED` | `false`; `true` copies local repo to B2/R2 after backup |
| `RESTIC_OFFSITE_REPOSITORY` | S3 URL e.g. `s3:https://s3...backblazeb2.com/bucket/pi-gateway` |
| `RESTIC_OFFSITE_ACCESS_KEY_ID` | B2/R2 key (S3-compatible) |
| `RESTIC_OFFSITE_SECRET_ACCESS_KEY` | B2/R2 secret |

SSD restic alone is **not** 3-2-1. Run `make backup-pull` / `make backup-cron` / `make backup-restore-drill`. See [ADR-004](adr/004-backup-3321.md) and [SLO.md](SLO.md).

## TLS

| Variable | Default | Description |
|----------|---------|-------------|
| `ENABLE_TLS` | `true` | Caddy HTTPS for `*.home` |
| `WEAK_TLS_OK` | (unset) | Required to set `ENABLE_TLS=false` |
| `N8N_SECURE_COOKIE` | `true` | Must be true when TLS on |

## n8n

| Variable | Description |
|----------|-------------|
| `N8N_ENCRYPTION_KEY` | Credential encryption (≥32 chars; `openssl rand -hex 24`) |
| `N8N_WEBHOOK_SECRET` | Webhook URL suffix (Kuma) |
| `N8N_KUMA_WEBHOOK_URL` | Optional; auto-built from secret if empty |

If `N8N_ENCRYPTION_KEY` is empty on Pi, `ensure-n8n-encryption-key.sh` generates it during post-deploy. **Do not change** — existing n8n credentials become unreadable.

## NetAlertX (network inventory)

| Variable | Default | Description |
|----------|---------|-------------|
| `ENABLE_NETALERTX` | `true` | NetAlertX container + setup |
| `NETALERTX_PORT` | `20211` | UI (loopback; Caddy `devices.home`) |
| `NETALERTX_LISTEN_ADDR` | `172.17.0.1` | Host-network docker0; Caddy `host.docker.internal` proxy. Avoid `0.0.0.0`. |
| `NETALERTX_SCAN_SUBNETS` | (empty) | ARP scan; if empty, `LAN_SUBNET_CIDR` + `PI_INTERFACE` |
| `NETALERTX_PASSWORD` | (empty → `AGH_ADMIN_PASSWORD`) | NetAlertX UI password |
| `NETALERT_NOTIFY_VIA` | `telegram` | Native plugin `sendMessage`. `n8n` yok. |

Details: `docs/FAZ4.md`

## Home ops (Grafana / İBB)

| Variable | Default | Description |
|----------|---------|-------------|
| `ADGUARD_METRICS_TOP_N` | `12` (max 25) | Grafana bar: top client / blocked / queried domain |
| `IBB_AQI_STATION_ID` | empty | İBB istasyon UUID. Boş = `IBB_HOME_*` / `QUAKE_HOME_*` en yakın (Mobil atlanır) |
| `IBB_HOME_LAT` / `IBB_HOME_LON` | `QUAKE_HOME_*` veya Aksaray civarı | En yakın HKI istasyonu |
| `IBB_HKI_WARN` | `51` | Telegram eşik (İBB sarı bant). scrape fail = Telegram yok |
| `NOTIFY_IBB_REPEAT_SEC` | `21600` | Aynı HKI-kötü durumunda tekrar (6 saat) |
| `IBB_HTTP_TIMEOUT_SEC` | `20` | İBB API timeout |
