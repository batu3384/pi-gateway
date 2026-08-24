#!/usr/bin/env bash
# Bildirim yardımcıları (Telegram). health-check, backup, systemd tarafından kullanılır.
set -euo pipefail

NOTIFY_STATE_DIR="${NOTIFY_STATE_DIR:-/run/pi-gateway/notify}"
NOTIFY_COOLDOWN_SEC="${NOTIFY_COOLDOWN_SEC:-300}"
NOTIFY_REPEAT_SEC="${NOTIFY_REPEAT_SEC:-3600}"
NOTIFY_SLO_REPEAT_SEC="${NOTIFY_SLO_REPEAT_SEC:-86400}"
NOTIFY_DISK_REPEAT_SEC="${NOTIFY_DISK_REPEAT_SEC:-86400}"

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

# Telegram bildirimlerinde panel linki (TS IP :PORT öncelikli)
notify_panel_url() {
  local panel_id="$1"
  local remote_dir="${REMOTE_DIR:-${HOME}/pi-gateway}"
  local panels_py="${remote_dir}/scripts/lib/telegram-panels.py"
  local url=""
  if [[ -f "$panels_py" ]]; then
    url="$(PANEL_PROTOCOL="${PANEL_PROTOCOL:-}" ENABLE_TLS="${ENABLE_TLS:-}" \
      PI_STATIC_IP="${PI_STATIC_IP:-}" LAN_DOMAIN="${LAN_DOMAIN:-home}" \
      NETALERTX_PORT="${NETALERTX_PORT:-20211}" \
      python3 "$panels_py" panel_url "$panel_id" 2>/dev/null || true)"
  fi
  if [[ -n "$url" ]]; then
    printf '%s' "$url"
  else
    panel_url "$panel_id"
  fi
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

notify_repeat_sec_for() {
  local key="$1"
  case "$key" in
    health-slo-backup) printf '%s' "$NOTIFY_SLO_REPEAT_SEC" ;;
    disk-*) printf '%s' "$NOTIFY_DISK_REPEAT_SEC" ;;
    restic-ok) printf '%s' "${NOTIFY_BACKUP_OK_COOLDOWN_SEC:-86400}" ;;
    *) printf '%s' "$NOTIFY_REPEAT_SEC" ;;
  esac
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

notify_transition_peek() {
  local key="$1"
  local new_state="$2"
  local state_file stamp_file prev now last repeat
  notify_ensure_dir
  state_file="${NOTIFY_STATE_DIR}/${key}.state"
  stamp_file="${NOTIFY_STATE_DIR}/${key}"
  prev="$(cat "$state_file" 2>/dev/null || echo ok)"
  now="$(date +%s)"
  repeat="$(notify_repeat_sec_for "$key")"

  if [[ "$new_state" == "ok" ]]; then
    [[ "$prev" != "ok" ]] && return 0
    return 1
  fi

  if [[ "$prev" != "fail" ]]; then
    return 0
  fi
  last="$(cat "$stamp_file" 2>/dev/null || echo 0)"
  (( now - last >= repeat )) && return 0
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
  local cooldown
  cooldown="$(notify_repeat_sec_for "$key")"

  notify_enabled || return 0
  notify_rate_ok "$key" "$cooldown" || return 0

  local text
  text="$(printf '%s\n\n%s' "$title" "$body")"
  notify_send_message "$text" "$parse_mode" || true
}

# HTML: host + özet + detay + aksiyon + dipnot
notify_html_alert() {
  local host="$1"
  local headline="$2"
  local detail="$3"
  local action="${4:-}"
  local footnote="${5:-}"
  local lines
  lines="$(printf '<b>%s</b>\n%s\n\n<code>%s</code>' \
    "$(notify_escape_html "$host")" \
    "$(notify_escape_html "$headline")" \
    "$(notify_escape_html "$detail")")"
  if [[ -n "$action" ]]; then
    lines="$(printf '%s\n\n<b>Ne yapmalı?</b>\n%s' "$lines" "$action")"
  fi
  if [[ -n "$footnote" ]]; then
    lines="$(printf '%s\n\n<i>%s</i>' "$lines" "$footnote")"
  fi
  printf '%s' "$lines"
}

notify_dns_fail() {
  local host="$1"
  local details="$2"
  local gateway body
  gateway="$(panel_url gateway)"
  esc_gw="$(notify_escape_html "$gateway")"
  body="$(notify_html_alert "$host" \
    "DNS / çekirdek stack sağlık kontrolü başarısız." \
    "$details" \
    "• Pi güç ve ağ bağlantısını kontrol edin
• Geçici çözüm: router DNS → 8.8.8.8
• Panel: ${esc_gw}" \
    "Kritik — saatte en fazla bir hatırlatma.")"
  notify_send_with_transition "health-dns" "fail" "⚠️ Pi Gateway · DNS" "$body" "HTML"
}

notify_dns_recovered() {
  local host="$1"
  local body
  body="$(notify_html_alert "$host" "DNS / çekirdek stack normale döndü." "Tüm kontroller geçti." "" "")"
  notify_send_with_transition "health-dns" "ok" "✅ Pi Gateway · DNS" "$body" "HTML"
}

notify_optional_warn() {
  local host="$1"
  local details="$2"
  local body
  body="$(notify_html_alert "$host" \
    "Opsiyonel servis(ler) ayakta değil — ev DNS etkilenmez." \
    "$details" \
    "Acil değil; uygun zamanda container / servis loglarına bakın." \
    "Bilgi — saatte en fazla bir hatırlatma.")"
  notify_send_with_transition "health-optional" "fail" "📋 Pi Gateway · Opsiyonel" "$body" "HTML"
}

notify_optional_recovered() {
  notify_transition_peek "health-optional" "ok" || return 0
  notify_transition_commit "health-optional" "ok"
}

notify_backup_ok() {
  local stamp="$1"
  local body
  body="$(printf '<b>Yedekleme tamamlandı</b>\n<b>Zaman:</b> %s\n\n<i>Günlük en fazla bir özet.</i>' \
    "$(notify_escape_html "$stamp")")"
  notify_transition_commit "restic-fail" "ok" 2>/dev/null || true
  notify_telegram "✅ Pi Gateway · Yedek" "$body" "restic-ok" "HTML"
}

notify_backup_fail() {
  local details="$1"
  local body
  body="$(notify_html_alert "$(hostname -s 2>/dev/null || echo pi-gateway)" \
    "Yerel Restic yedeklemesi başarısız veya atlandı." \
    "$details" \
    "• SSD takılı mı, mount OK mi?
• <code>ENABLE_RESTIC=true</code> mi?
• Pi: <code>journalctl -u pi-gateway-backup -n 30</code>" \
    "Saatte en fazla bir hatırlatma.")"
  notify_send_with_transition "restic-fail" "fail" "⚠️ Pi Gateway · Yedek" "$body" "HTML"
}

notify_health_systemd_fail() {
  local host="$1"
  local body
  body="$(notify_html_alert "$host" \
    "Zamanlanmış sağlık kontrolü (systemd) başarısız çıktı." \
    "journalctl -t pi-gateway-health -n 20" \
    "Pi üzerinde yukarıdaki komutla ayrıntıya bakın." \
    "Saatte en fazla bir hatırlatma.")"
  notify_send_with_transition "health-systemd" "fail" "⚠️ Pi Gateway · Sağlık" "$body" "HTML"
}

notify_health_systemd_ok() {
  notify_transition_peek "health-systemd" "ok" || return 0
  notify_transition_commit "health-systemd" "ok"
}

notify_slo_backup() {
  local host="$1"
  local details="$2"
  local body
  body="$(notify_html_alert "$host" \
    "Offsite yedek / restore drill SLA — DNS etkilenmez." \
    "$details" \
    "Mac: <code>make backup-pull</code>
Restore drill: <code>make backup-restore-drill</code>" \
    "Bilgi — günde en fazla bir hatırlatma.")"
  notify_send_with_transition "health-slo-backup" "fail" "📋 Pi Gateway · Yedek SLA" "$body" "HTML"
}

notify_slo_backup_ok() {
  notify_transition_peek "health-slo-backup" "ok" || return 0
  notify_transition_commit "health-slo-backup" "ok"
}

notify_disk_warn() {
  local mount="$1"
  local detail="$2"
  local key="disk-${mount//\//-}"
  local body
  body="$(notify_html_alert "$(hostname -s 2>/dev/null || echo pi-gateway)" \
    "Disk uyarısı: ${mount}" \
    "$detail" \
    "Pi: <code>df -h ${mount}</code>
Gerekirse log / eski yedek temizliği." \
    "Günde en fazla bir hatırlatma.")"
  notify_send_with_transition "$key" "fail" "📋 Pi Gateway · Disk" "$body" "HTML"
}

notify_sd_warn() {
  local host="$1"
  local details="$2"
  local recovered="${3:-0}"
  local headline action
  if [[ "$recovered" == "1" ]]; then
    headline="SD / root dosya sistemi — otomatik kurtarma denendi, sorun sürüyor."
    action="• Güvenli kapat-aç
• SD sağlığını kontrol edin
• Uzun vadede SSD boot düşünün"
  else
    headline="SD kart read-only veya root yazılamıyor."
    action="• Pi'yi yeniden başlatın
• Tekrar olursa SD kartı değiştirin"
  fi
  local body
  body="$(notify_html_alert "$host" "$headline" "$details" "$action" \
    "Kritik — saatte en fazla bir hatırlatma.")"
  notify_send_with_transition "sd-health" "fail" "⚠️ Pi Gateway · SD Kart" "$body" "HTML"
}

notify_sd_recovered() {
  local host="$1"
  local body
  body="$(notify_html_alert "$host" \
    "Root read-only tespit edildi — otomatik kurtarma uygulandı." \
    "Servisler yeniden ayağa kalktı." "" "")"
  notify_send_with_transition "sd-health" "ok" "✅ Pi Gateway · SD Kart" "$body" "HTML"
}

notify_stack_recovered() {
  local host="$1"
  local details="$2"
  local gateway body
  gateway="$(panel_url gateway)"
  esc_gw="$(notify_escape_html "$gateway")"
  body="$(notify_html_alert "$host" \
    "Stack otomatik kurtarma tamamlandı." \
    "$details" \
    "Panel: ${esc_gw}" \
    "Saatte en fazla bir özet.")"
  notify_send_with_transition "stack-recovered" "ok" "✅ Pi Gateway · Stack" "$body" "HTML"
}

notify_ssd_degraded() {
  local host="$1"
  local details="$2"
  local body
  body="$(notify_html_alert "$host" \
    "SSD veri diski yok — degraded mod (DNS SD üzerinde)." \
    "$details" \
    "SSD takılınca tam stack restore otomatik denenir." \
    "Kritik — saatte en fazla bir hatırlatma.")"
  notify_send_with_transition "ssd-degraded" "fail" "⚠️ Pi Gateway · SSD" "$body" "HTML"
}

notify_ssd_restored() {
  local host="$1"
  local body
  body="$(notify_html_alert "$host" \
    "SSD tekrar bağlandı — tam stack restore başlatıldı." \
    "Degraded moddan çıkılıyor." "" "")"
  notify_send_with_transition "ssd-degraded" "ok" "✅ Pi Gateway · SSD" "$body" "HTML"
}

notify_test() {
  local gateway body
  gateway="$(panel_url gateway)"
  body="$(printf 'Telegram bildirim kanalı aktif.\n\n<b>Panel:</b> %s\n<b>Menü:</b> <code>/menu</code>\n\n<i>Otomatik uyarılar bu bottan; AI bültenleri Hermes cron.</i>' \
    "$(notify_escape_html "$gateway")")"
  notify_telegram "✅ Pi Gateway · Test" "$body" "test-once" "HTML"
}

# NetAlertX yeni cihaz (html_detail: netalert-devices.py format_html_detail)
notify_netalert_new_devices() {
  local html_detail="$1"
  local count="${2:-1}"
  local host headline body action footnote panel

  host="$(hostname -s 2>/dev/null || echo pi-gateway)"
  panel="$(notify_panel_url devices)"
  if (( count == 1 )); then
    headline="Ev ağında yeni cihaz tespit edildi."
  else
    headline="${count} yeni cihaz tespit edildi — ev ağı."
  fi
  action="$(printf '• Tanımıyorsan NetAlertX panosundan incele.\n• Panel: %s' "$(notify_escape_html "$panel")")"
  footnote="Events tabanlı — işlenmiş olay tekrar bildirilmez."
  body="$(printf '<b>%s</b>\n%s\n\n%s' \
    "$(notify_escape_html "$host")" \
    "$(notify_escape_html "$headline")" \
    "$html_detail")"
  body="$(printf '%s\n\n<b>Ne yapmalı?</b>\n%s' "$body" "$action")"
  body="$(printf '%s\n\n<i>%s</i>' "$body" "$(notify_escape_html "$footnote")")"
  notify_telegram "📋 Pi Gateway · Ağ" "$body" "netalert-newdev" "HTML"
}

notify_netalert_offline_devices() {
  local html_detail="$1"
  local count="${2:-1}"
  local host headline body action footnote panel

  host="$(hostname -s 2>/dev/null || echo pi-gateway)"
  panel="$(notify_panel_url devices)"
  if (( count == 1 )); then
    headline="Ev ağında cihaz offline oldu."
  else
    headline="${count} cihaz offline — ev ağı."
  fi
  action="$(printf '• Panel: %s\n• Beklenen cihazsa sorun yok; tanımıyorsan incele.' "$(notify_escape_html "$panel")")"
  footnote="Events tabanlı — işlenmiş olay tekrar bildirilmez."
  body="$(printf '<b>%s</b>\n%s\n\n%s' \
    "$(notify_escape_html "$host")" \
    "$(notify_escape_html "$headline")" \
    "$html_detail")"
  body="$(printf '%s\n\n<b>Ne yapmalı?</b>\n%s' "$body" "$action")"
  body="$(printf '%s\n\n<i>%s</i>' "$body" "$(notify_escape_html "$footnote")")"
  notify_telegram "📋 Pi Gateway · Ağ" "$body" "netalert-offline" "HTML"
}

watchtower_notification_url() {
  if notify_enabled; then
    printf 'telegram://%s@telegram?chats=%s' \
      "$TELEGRAM_BOT_TOKEN" "$TELEGRAM_CHAT_ID"
  fi
}
