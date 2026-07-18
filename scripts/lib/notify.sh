#!/usr/bin/env bash
# Bildirim yardımcıları (Telegram). health-check, backup, systemd tarafından kullanılır.
set -euo pipefail

NOTIFY_STATE_DIR="${NOTIFY_STATE_DIR:-/run/pi-gateway/notify}"
NOTIFY_COOLDOWN_SEC="${NOTIFY_COOLDOWN_SEC:-300}"

LAN_DOMAIN="${LAN_DOMAIN:-home}"

notify_enabled() {
  [[ -n "${TELEGRAM_BOT_TOKEN:-}" && -n "${TELEGRAM_CHAT_ID:-}" ]]
}

panel_url() {
  local host="$1"
  local proto="${PANEL_PROTOCOL:-}"
  if [[ -z "$proto" ]]; then
    if [[ "${ENABLE_TLS:-false}" == "true" ]]; then
      proto=https
    else
      proto=http
    fi
  fi
  printf '%s://%s.%s' "$proto" "$host" "${LAN_DOMAIN}"
}

notify_rate_ok() {
  local key="$1"
  local now last owner
  owner="${NOTIFY_OWNER:-${PI_USER:-batu}}"
  if [[ "$(id -u)" -eq 0 ]]; then
    install -d -m 0775 -o "$owner" -g "$owner" "$NOTIFY_STATE_DIR" 2>/dev/null \
      || mkdir -p "$NOTIFY_STATE_DIR"
  else
    mkdir -p "$NOTIFY_STATE_DIR" 2>/dev/null || true
  fi
  now="$(date +%s)"
  last="$(cat "${NOTIFY_STATE_DIR}/${key}" 2>/dev/null || echo 0)"
  if (( now - last < NOTIFY_COOLDOWN_SEC )); then
    return 1
  fi
  echo "$now" > "${NOTIFY_STATE_DIR}/${key}" 2>/dev/null || return 0
  return 0
}

notify_escape_html() {
  local text="$1"
  text="${text//&/&amp;}"
  text="${text//</&lt;}"
  text="${text//>/&gt;}"
  text="${text//\'/&#39;}"
  printf '%s' "$text"
}

notify_send_message() {
  local text="$1"
  local parse_mode="${2:-}"
  local err

  if [[ -n "$parse_mode" ]]; then
    if err="$(curl -fsS -X POST "https://api.telegram.org/bot${TELEGRAM_BOT_TOKEN}/sendMessage" \
      -d "chat_id=${TELEGRAM_CHAT_ID}" \
      -d "parse_mode=${parse_mode}" \
      --data-urlencode "text=${text}" \
      -d "disable_web_page_preview=true" 2>&1)"; then
      return 0
    fi
  elif err="$(curl -fsS -X POST "https://api.telegram.org/bot${TELEGRAM_BOT_TOKEN}/sendMessage" \
    -d "chat_id=${TELEGRAM_CHAT_ID}" \
    --data-urlencode "text=${text}" \
    -d "disable_web_page_preview=true" 2>&1)"; then
    return 0
  fi

  echo "[notify] Telegram gonderilemedi: ${err:-bilinmeyen hata}" >&2
  return 1
}

notify_telegram() {
  local title="$1"
  local body="$2"
  local key="${3:-alert}"
  local parse_mode="${4:-}"

  notify_enabled || return 0
  notify_rate_ok "$key" || return 0

  local text
  text="$(printf '%s\n\n%s' "$title" "$body")"
  notify_send_message "$text" "$parse_mode" || true
}

# Kullanıcıya giden standart Türkçe mesajlar (UTF-8)
notify_dns_fail() {
  local host="$1"
  local details="$2"
  local gateway
  gateway="$(panel_url gateway)"
  local body
  body="$(printf '<b>%s</b> — DNS sağlık kontrolü başarısız.\n\n<code>%s</code>\n\n<b>Ne yapmalı?</b>\n• Pi açık mı kontrol edin\n• Geçici: router DNS → 8.8.8.8\n• Panel: %s' \
    "$host" "$(notify_escape_html "$details")" "$gateway")"
  notify_telegram "⚠️ Pi Gateway" "$body" "health-dns" "HTML"
}

notify_backup_ok() {
  local stamp="$1"
  local body
  body="$(printf 'Restic yedeklemesi tamamlandı.\n<b>Zaman:</b> %s' "$stamp")"
  notify_telegram "✅ Pi Gateway — Yedek" "$body" "restic-ok" "HTML"
}

notify_health_systemd_fail() {
  local host="$1"
  local body
  body="$(printf '<b>%s</b> — zamanlanmış sağlık kontrolü başarısız.\n\nDetay için Pi üzerinde:\n<code>journalctl -t pi-gateway-health -n 20</code>' "$host")"
  notify_telegram "⚠️ Pi Gateway — Sağlık" "$body" "health-systemd" "HTML"
}

notify_disk_warn() {
  local mount="$1"
  local pct="$2"
  local body
  body="$(printf '<b>%s</b> diski <b>%%%s</b> dolu.\n\n<code>df -h %s</code>' "$mount" "$pct" "$mount")"
  notify_telegram "⚠️ Pi Gateway — Disk" "$body" "disk-warn" "HTML"
}

notify_sd_warn() {
  local host="$1"
  local details="$2"
  local recovered="${3:-0}"
  local body
  if [[ "$recovered" == "1" ]]; then
    body="$(printf '<b>%s</b> — SD kart / root dosya sistemi sorunu.\nOtomatik kurtarma denendi ama sorun suruyor.\n\n<code>%s</code>\n\n<b>Ne yapmalı?</b>\n• Pi''yi guvenli kapatip acin\n• SD kart sagligini kontrol edin\n• Uzun vadede SSD''den boot dusunun' \
      "$host" "$(notify_escape_html "$details")")"
  else
    body="$(printf '<b>%s</b> — SD kart read-only veya yazilamiyor.\n\n<code>%s</code>\n\n<b>Ne yapmalı?</b>\n• Pi''yi yeniden baslatin\n• Sorun tekrarlarsa SD karti degistirin' \
      "$host" "$(notify_escape_html "$details")")"
  fi
  notify_telegram "⚠️ Pi Gateway — SD Kart" "$body" "sd-warn" "HTML"
}

notify_sd_recovered() {
  local host="$1"
  local body
  body="$(printf '<b>%s</b> — root read-only tespit edildi, otomatik kurtarma yapildi.\n\nServisler yeniden ayaga kalkti.\nSD karti izlemeye devam ediyoruz.' "$host")"
  notify_telegram "✅ Pi Gateway — SD Kurtarma" "$body" "sd-recovered" "HTML"
}

notify_stack_recovered() {
  local host="$1"
  local details="$2"
  local gateway
  gateway="$(panel_url gateway)"
  local body
  body="$(printf '<b>%s</b> — stack otomatik kurtarildi.\n\n<code>%s</code>\n\nPanel: %s' \
    "$host" "$(notify_escape_html "$details")" "$gateway")"
  notify_telegram "✅ Pi Gateway — Stack Kurtarma" "$body" "stack-recovered" "HTML"
}

notify_ssd_degraded() {
  local host="$1"
  local details="$2"
  local body
  body="$(printf '<b>%s</b> — SSD veri diski yok; <b>degraded mod</b> (DNS SD uzerinde).\n\n<code>%s</code>\n\nSSD takilinca otomatik tam stack restore denenir.' \
    "$host" "$(notify_escape_html "$details")")"
  notify_telegram "⚠️ Pi Gateway — SSD Degraded" "$body" "ssd-degraded" "HTML"
}

notify_ssd_restored() {
  local host="$1"
  local body
  body="$(printf '<b>%s</b> — SSD tekrar baglandi; tam stack restore baslatildi.' "$host")"
  notify_telegram "✅ Pi Gateway — SSD Geri" "$body" "ssd-restored" "HTML"
}

notify_test() {
  local gateway
  gateway="$(panel_url gateway)"
  local body
  body="$(printf 'Bildirimler aktif.\n\n<b>Ana panel:</b> %s\n<b>Menü:</b> Mac''te <code>make telegram-menu</code>\n\n<i>Bu bot yalnızca uyarı gönderir; mesajlarınıza cevap vermez.</i>' "$gateway")"
  notify_telegram "✅ Pi Gateway" "$body" "test-once" "HTML"
}

watchtower_notification_url() {
  if notify_enabled; then
    printf 'telegram://%s@telegram?chats=%s' \
      "$TELEGRAM_BOT_TOKEN" "$TELEGRAM_CHAT_ID"
  fi
}
