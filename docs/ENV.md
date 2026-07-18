# Ortam Değişkenleri (.env)

## Zorunlu (deploy öncesi)

| Değişken | Açıklama |
|----------|----------|
| `PI_HOST` / `PI_STATIC_IP` | Pi adresi |
| `AGH_ADMIN_PASSWORD` | AdGuard admin (≥12 karakter) |
| `LAN_GATEWAY`, `LAN_SUBNET_CIDR` | `discover-remote.sh` ile dolar |

## DNS / AdGuard

| Değişken | Varsayılan |
|----------|------------|
| `ADGUARD_BOOT_WAIT_SEC` | 180 |
| `ADGUARD_MIN_FILTER_RULES` | 100000 |
| `ADGUARD_MIN_REWRITES` | 7 |
| `ADGUARD_BLOCKED_TTL` | 60 |

## Güvenlik

| Değişken | Açıklama |
|----------|----------|
| `UFW_ADMIN_EXPOSURE` | `full` veya `caddy-only` |
| `TELEGRAM_BOT_TOKEN` | @BotFather token |
| `TELEGRAM_CHAT_ID` | Bildirim kanalı |
| `CROWDSEC_BOUNCER_KEY` | İlk kurulumda otomatik yazılır |

## Syncthing

| Değişken | Açıklama |
|----------|----------|
| `SYNCTHING_MAC_DEVICE_ID` | Mac cihaz ID |
| `SYNCTHING_GUI_USER` / `SYNCTHING_GUI_PASSWORD` | Web arayüzü |

## SSD / depolama

| Değişken | Varsayılan | Açıklama |
|----------|------------|----------|
| `STORAGE_TYPE` | `hybrid` | **Üretim:** SD root + SSD veri (`/mnt/ssd`). `ssd-data` alias. |
| `STORAGE_FALLBACK_SD` | `false` | SSD yokken SD üzerinde core DNS (fail-closed varsayılan) |
| `ENABLE_DOCKER_SSD` | `false` | `true`: Docker `data-root` SSD'ye; JMicron USB'de I/O riski |
| `DOCKER_SSD_ROOT` | `/mnt/ssd/docker` | `ENABLE_DOCKER_SSD=true` iken hedef |
| `STACK_RECOVER_COOLDOWN_SEC` | `180` | compose up sonrası otomatik recover bekleme |
| `STACK_BOOT_GRACE_SEC` | `120` | Boot sonrası recover erteleme |

Deneysel `ssd-root`: `docs/SSD-ROOT.md` + `scripts/mac/migrate-sd-boot-ssd-root.sh`

## Yedekleme

| Değişken | Açıklama |
|----------|----------|
| `ENABLE_RESTIC` | true/false |
| `RESTIC_PASSWORD` | Repo şifresi |
| `RESTIC_REPOSITORY` | SSD üzerindeki yol |
| `MAC_BACKUP_DEST` | Mac `backup-pull` hedefi |

## Watchtower

`ENABLE_WATCHTOWER=true` ve:

```
WATCHTOWER_NOTIFICATION_URL=telegram://TOKEN@telegram?chats=CHAT_ID
```

Tam liste: `.env.example`

## n8n

| Değişken | Açıklama |
|----------|----------|
| `N8N_ENCRYPTION_KEY` | Credential şifreleme (≥32 karakter; `openssl rand -hex 24`) |
| `N8N_WEBHOOK_SECRET` | Webhook URL son eki (Kuma, Forgejo) |
| `N8N_KUMA_WEBHOOK_URL` | İsteğe bağlı; boşsa secret ile otomatik |
| `N8N_FORGEJO_WEBHOOK_URL` | İsteğe bağlı; boşsa secret ile otomatik |

Pi'de `N8N_ENCRYPTION_KEY` boşsa `ensure-n8n-encryption-key.sh` post-deploy sırasında üretir. **Değiştirmeyin** — mevcut n8n credential'ları okunamaz hale gelir.
