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
