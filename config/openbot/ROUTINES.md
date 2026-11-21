# Jarvis — native OpenBot (Docker yok)

Kurulum:

```bash
bash ~/pi-gateway/scripts/pi/remove-openbot-docker.sh
bash ~/pi-gateway/scripts/pi/setup-openbot-native-server.sh
# Gerekirse: sudo openbot login
```

Servis: `openbot.service` — sunucu **Heimdall**.
- **Jarvis:** `opencode` / `zai-coding-plan/glm-5.3` (`medium`, `computerUse=false`) + Tavily · otomatik yedek: `glm-5-turbo` → `antigravity/gemini-3.8-flash`.
- **Falcon, Spider, Ultron, Cipher, Iron:** `antigravity` / `gemini-3.8-flash` (`medium`) · otomatik yedek: `opencode/zai-coding-plan/glm-5.3` → `glm-5-turbo`.

Filo (`setup-openbot-fleet.sh`, veri `/mnt/ssd/openbot-native/fleet`, 10 sıralı rutin):

| Saat | Ajan | İş |
|------|------|----|
| 5 dk | watchdog (LLM yok) | 13 konteyner, DNS :53, 75°C, 350MB RAM, disk %85, OOM, systemd failed, 20dk OpenBot rutin fail + günlük `shared/` rotasyonu |
| 07:30 | Falcon | Sabah gündem (5–8 haber → `shared/tech_radar.md`) |
| 07:45 | Spider | Kariyer ve eğitim taraması (`profile.md` + `user_profile.md` → `shared/career_pipeline.md`) |
| 08:00 | Jarvis | Sabah sistem (`jarvis-health-brief.sh`: anlık + 7g VictoriaMetrics trend + OpenBot 24s → `shared/system_health.md`) |
| 08:15 | Iron | Sabah Stratejik Brifingi (tüm taze `shared/` çıktıları → 1 Büyük Taş + max 2 iş → `shared/weekly_plan.md`) |
| eşik | Jarvis | `jarvis-send` → sohbet mesajı (anlık uyarı) |
| 13:00 | Cipher | İngilizce pratik (A0→B2 + `shared/english_log.md` Spaced Repetition) |
| 19:00 | Falcon | Akşam gündem (sabah tekrarsız → `shared/tech_radar.md`) |
| Salı 20:30 | Ultron | Kültür Monografı · Salı (`render-ultron-pdf.sh` A4 PDF → `shared/culture_library.md`) |
| Cmt 18:00 | Ultron | Kültür Monografı · Cumartesi (`render-ultron-pdf.sh` A4 PDF → `shared/culture_library.md`) |
| 21:45 | Iron | Akşam Kapanışı & Debottlenecking (`[ ]/[x]` + kök neden) |
| Pazar 20:00 | Iron | Haftalık Stratejik Sprint Planı (`shared/weekly_plan.md`) |

Ortak SSOT profil: `shared/user_profile.md` (şablon: `config/openbot/fleet/user-profile.md.template`, kişisel bilgiler yalnızca Pi'de tutulur). Uzun `shared/*.md` dosyaları `fleet-shared-rotate.sh` ile `shared/archive/YYYY-MM/` altına taşınır.

Emekli edilen eski Jarvis bültenleri ve eski rutin adları `sync-fleet-routines.py` tarafından pasifleştirilir (`--check` sıfır drift doğrular).

Uyarılar: `NOTIFY_BACKEND=openbot` → `jarvis-send.sh --wait` (tur bitince mobil push). Doğrulama: `FLEET_VERIFY_LIVE_ALERT=true bash scripts/pi/verify-openbot-fleet.sh`.
