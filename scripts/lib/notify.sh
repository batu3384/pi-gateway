#!/usr/bin/env bash
# Bildirim yardımcıları (Telegram). health-check, backup, systemd tarafından kullanılır.
set -euo pipefail

NOTIFY_STATE_DIR="${NOTIFY_STATE_DIR:-/run/pi-gateway/notify}"
# İlk FAIL bildirimi için minimum aralık (çift tetiklemeyi keser)
NOTIFY_COOLDOWN_SEC="${NOTIFY_COOLDOWN_SEC:-300}"
# Aynı sorun sürerken tekrar hatırlatma (edge-trigger sonrası)
NOTIFY_REPEAT_SEC="${NOTIFY_REPEAT_SEC:-3600}"

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

notify_ensure_dir() {
  local owner
  owner="${NOTIFY_OWNER:-${PI_USER:-pi}}"
  if [[ "$(id -u)" -eq 0 ]]; then
    install -d -m 0775 -o "$owner" -g "$owner" "$NOTIFY_STATE_DIR" 2>/dev/null \
      || mkdir -p "$NOTIFY_STATE_DIR"
  else
    mkdir -p "$NOTIFY_STATE_DIR" 2>/dev/null || true
  fi
}

notify_rate_ok() {
  local key="$1"
  local cooldown="${2:-$NOTIFY_COOLDOWN_SEC}"
  local now last
  notify_ensure_dir
  now="$(date +%s)"
  last="$(cat "${NOTIFY_STATE_DIR}/${key}" 2>/dev/null || echo 0)"
  if (( now - last < cooldown )); then
    return 1
  fi
  echo "$now" > "${NOTIFY_STATE_DIR}/${key}" 2>/dev/null || return 0
  return 0
}

# Edge-trigger: ok→fail hemen; fail sürerken NOTIFY_REPEAT_SEC; fail→ok recovery.
# peek = gönderimden önce (state yazma); commit = Telegram başarılı sonrası.
notify_transition_peek() {
  local key="$1"
  local new_state="$2" # ok|fail
  local state_file stamp_file prev now last
  notify_ensure_dir
  state_file="${NOTIFY_STATE_DIR}/${key}.state"
  stamp_file="${NOTIFY_STATE_DIR}/${key}"
  prev="$(cat "$state_file" 2>/dev/null || echo ok)"
  now="$(date +%s)"

  if [[ "$new_state" == "ok" ]]; then
    [[ "$prev" != "ok" ]] && return 0
    return 1
  fi

  if [[ "$prev" != "fail" ]]; then
    return 0
  fi
  last="$(cat "$stamp_file" 2>/dev/null || echo 0)"
  (( now - last >= NOTIFY_REPEAT_SEC )) && return 0
  return 1
}

notify_transition_commit() {
  local key="$1"
  local new_state="$2"
  local state_file stamp_file now
  notify_ensure_dir
  state_file="${NOTIFY_STATE_DIR}/${key}.state"
  stamp_file="${NOTIFY_STATE_DIR}/${key}"
  now="$(date +%s)"
  echo "$new_state" > "$state_file" 2>/dev/null || true
  echo "$now" > "$stamp_file" 2>/dev/null || true
}

# Başarılı gönderim sonrası state güncelle; başarısızsa sessiz kalma riski yok.
notify_send_with_transition() {
  local key="$1"
  local new_state="$2"
  local title="$3"
  local body="$4"
  local parse_mode="${5:-}"

  notify_enabled || return 0
  notify_transition_peek "$key" "$new_state" || return 0

  local text
  text="$(printf '%s\n\n%s' "$title" "$body")"
  if notify_send_message "$text" "$parse_mode"; then
    notify_transition_commit "$key" "$new_state"
  fi
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
  local gateway body
  gateway="$(panel_url gateway)"
  body="$(printf '<b>%s</b> — DNS / çekirdek stack sağlık kontrolü başarısız.\n\n<code>%s</code>\n\n<b>Ne yapmalı?</b>\n• Pi açık mı kontrol edin\n• Geçici: router DNS → 8.8.8.8\n• Panel: %s\n\n<i>Aynı sorun sürerken en fazla saatte bir hatırlatılır.</i>' \
    "$host" "$(notify_escape_html "$details")" "$gateway")"
  notify_send_with_transition "health-dns" "fail" "⚠️ Pi Gateway" "$body" "HTML"
}

notify_dns_recovered() {
  local host="$1"
  local body
  body="$(printf '<b>%s</b> — DNS / çekirdek stack tekrar sağlıklı.' "$host")"
  notify_send_with_transition "health-dns" "ok" "✅ Pi Gateway" "$body" "HTML"
}

notify_optional_warn() {
  local host="$1"
  local details="$2"
  local body
  body="$(printf '<b>%s</b> — opsiyonel servis(ler) ayakta değil (DNS etkilenmez).\n\n<code>%s</code>' \
    "$host" "$(notify_escape_html "$details")" )"
  notify_send_with_transition "health-optional" "fail" "ℹ️ Pi Gateway" "$body" "HTML"
}

notify_optional_recovered() {
  notify_transition_peek "health-optional" "ok" || return 0
  notify_transition_commit "health-optional" "ok"
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
  body="$(printf '<b>%s</b> — SSD veri diski yok; <b>degraded mod</b> (DNS SD uzerinde).\n\n<code>%s</code>\n\nSSD takilinca otomatik tam stack restore denenir.\n\n<i>Ayni sorun surerken en fazla saatte bir hatirlatilir.</i>' \
    "$host" "$(notify_escape_html "$details")")"
  notify_send_with_transition "ssd-degraded" "fail" "⚠️ Pi Gateway — SSD Degraded" "$body" "HTML"
}

notify_ssd_restored() {
  local host="$1"
  local body
  body="$(printf '<b>%s</b> — SSD tekrar baglandi; tam stack restore baslatildi.' "$host")"
  notify_send_with_transition "ssd-degraded" "ok" "✅ Pi Gateway — SSD Geri" "$body" "HTML"
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
