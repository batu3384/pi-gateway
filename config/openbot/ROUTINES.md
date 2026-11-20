# Jarvis — native OpenBot (Docker yok)

Kurulum:

```bash
bash ~/pi-gateway/scripts/pi/remove-openbot-docker.sh
bash ~/pi-gateway/scripts/pi/setup-openbot-native-server.sh
# Gerekirse: sudo openbot login
```

Servis: `openbot.service` — sunucu **Heimdall**. Jarvis: `zai-coding-plan/glm-5.3-flash` + Tavily. Diğerleri: `gemini-3.8-flash` (Antigravity).

Filo (`setup-openbot-fleet.sh`, veri `/mnt/ssd/openbot-native/fleet`):

| Saat | Ajan | İş |
|------|------|----|
| 5 dk | watchdog (LLM yok) | AdGuard/unbound/caddy, 75°C, 350MB available, disk %85 |
| 07:30 | Falcon | Sabah gündem |
| 08:00 | Jarvis | Sabah sistem (haber yok) |
| eşik | Jarvis | `jarvis-send` → sohbet mesajı (saatsiz rutin API’de yok) |
| 08:15 | Iron | 3 odak |
| 09:30 | Spider | İlan |
| 13:00 | Cipher | İngilizce |
| 19:00 | Falcon | Akşam gündem |
| 20:30 | Ultron | Kültür dosyası |
| 21:45 | Iron | Gün kapanışı |
| Pazar 20:00 | Iron | Haftalık plan |

Jarvis eski 07:00 / 18:55 / 19:00 / 23:00 bültenleri kapalı. `jarvis-fx-prepare.timer` kapalı.

| Saat | Rutin |
|------|--------|
| 07:00 | Günaydın Panosu |
| 18:54 | `jarvis-fx-prepare.timer` → `.../pi-gateway-fx-latest.txt` |
| 18:55 | Piyasa Özeti |
| 19:00 | Akşam Gündem |
| 23:00 | Gece Teknoloji |

Uyarılar: `NOTIFY_BACKEND=openbot` → `jarvis-send.sh --wait` (tur bitince mobil push). Doğrulama: `FLEET_VERIFY_LIVE_ALERT=true bash scripts/pi/verify-openbot-fleet.sh`.

Jarvis host’ta çalışır: `docker`, `systemctl`, `~/pi-gateway/scripts/pi/*` — Hermes modeli.