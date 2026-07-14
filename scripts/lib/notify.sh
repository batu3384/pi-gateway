#!/usr/bin/env bash
# Bildirim yardımcıları (Telegram). health-check, backup, systemd tarafından kullanılır.
set -euo pipefail

NOTIFY_STATE_DIR="${NOTIFY_STATE_DIR:-/tmp/pi-gateway-notify}"
NOTIFY_COOLDOWN_SEC="${NOTIFY_COOLDOWN_SEC:-300}"

notify_enabled() {
  [[ -n "${TELEGRAM_BOT_TOKEN:-}" && -n "${TELEGRAM_CHAT_ID:-}" ]]
}

notify_rate_ok() {
  local key="$1"
  local now last
  mkdir -p "$NOTIFY_STATE_DIR"
  now="$(date +%s)"
  last="$(cat "${NOTIFY_STATE_DIR}/${key}" 2>/dev/null || echo 0)"
  if (( now - last < NOTIFY_COOLDOWN_SEC )); then
    return 1
  fi
  echo "$now" > "${NOTIFY_STATE_DIR}/${key}"
  return 0
}

notify_telegram() {
  local title="$1"
  local body="$2"
  local key="${3:-alert}"

  notify_enabled || return 0
  notify_rate_ok "$key" || return 0

  local text
  text="$(printf '%s\n%s' "$title" "$body")"
  curl -fsS -X POST "https://api.telegram.org/bot${TELEGRAM_BOT_TOKEN}/sendMessage" \
    -d "chat_id=${TELEGRAM_CHAT_ID}" \
    --data-urlencode "text=${text}" \
    --data-urlencode "disable_web_page_preview=true" >/dev/null 2>&1 || true
}

# Kullanıcıya giden standart Türkçe mesajlar (UTF-8)
notify_dns_fail() {
  local host="$1"
  local details="$2"
  local body
  body="$(printf '%s\n%s' "${host}: DNS sağlık kontrolü başarısız." "$details")"
  notify_telegram "⚠️ Pi Gateway — DNS sorunu" "$body" "health-fail"
}

notify_backup_ok() {
  local stamp="$1"
  local body
  body="$(printf 'Restic yedeklemesi tamamlandı.\nZaman: %s' "$stamp")"
  notify_telegram "✅ Pi Gateway — Yedek" "$body" "restic-ok"
}

notify_health_systemd_fail() {
  local host="$1"
  notify_telegram "⚠️ Pi Gateway — Uyarı" \
    "${host}: Zamanlanmış sağlık kontrolü başarısız." \
    "health-fail"
}

notify_disk_warn() {
  local mount="$1"
  local pct="$2"
  local body
  body="$(printf '%s diski %%%.0f dolu.\nKontrol: df -h %s' "$mount" "$pct" "$mount")"
  notify_telegram "⚠️ Pi Gateway — Disk uyarısı" "$body" "disk-warn"
}

notify_test() {
  local body
  body="$(printf 'Telegram bildirimleri aktif.\nBu bot yalnızca uyarı gönderir; mesajlarınıza cevap vermez.')"
  notify_telegram "✅ Pi Gateway" "$body" "test-once"
}

watchtower_notification_url() {
  if notify_enabled; then
    printf 'telegram://%s@telegram?chats=%s' \
      "$TELEGRAM_BOT_TOKEN" "$TELEGRAM_CHAT_ID"
  fi
}
