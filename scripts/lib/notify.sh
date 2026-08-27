#!/usr/bin/env bash
# Bildirim yardımcıları (Telegram). health-check, backup, systemd tarafından kullanılır.
set -euo pipefail

# Kalıcı — /run reboot'ta silinir, recover bildirimi kaybolurdu.
NOTIFY_STATE_DIR="${NOTIFY_STATE_DIR:-/var/lib/pi-gateway/notify}"
NOTIFY_LAST_ALIVE_FILE="${NOTIFY_LAST_ALIVE_FILE:-/var/lib/pi-gateway/last-alive}"
NOTIFY_COOLDOWN_SEC="${NOTIFY_COOLDOWN_SEC:-300}"
NOTIFY_REPEAT_SEC="${NOTIFY_REPEAT_SEC:-3600}"
NOTIFY_SLO_REPEAT_SEC="${NOTIFY_SLO_REPEAT_SEC:-86400}"
NOTIFY_DISK_REPEAT_SEC="${NOTIFY_DISK_REPEAT_SEC:-86400}"
# Boot notify: last-alive'dan bu kadar kısaysa atla (timer yarışı)
NOTIFY_BOOT_MIN_DOWN_SEC="${NOTIFY_BOOT_MIN_DOWN_SEC:-90}"

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
    install -d -m 0775 -o "$owner" -g "$owner" "$(dirname "$NOTIFY_LAST_ALIVE_FILE")" 2>/dev/null \
      || mkdir -p "$(dirname "$NOTIFY_LAST_ALIVE_FILE")"
  else
    mkdir -p "$NOTIFY_STATE_DIR" 2>/dev/null || true
    mkdir -p "$(dirname "$NOTIFY_LAST_ALIVE_FILE")" 2>/dev/null || true
  fi
}

# Health timer her tick — reboot downtime hesabı için.
notify_touch_alive() {
  local now
  notify_ensure_dir
  now="$(date +%s)"
  echo "$now" > "$NOTIFY_LAST_ALIVE_FILE" 2>/dev/null || true
}

# Telegram sesi (kullanıcıya):
#   Başlık: emoji + "Pi Gateway · KısaTürkçe"
#   Gövde: ne oldu (insan dili). Eng/ops jargon yok (inbox, stack, SLA, P2…).
#   Detay: teknik kanıt (code). Aksiyon: ne yapmalı. Sunucu satırı en altta.
notify_boot_up() {
  local host="$1"
  local down_sec="${2:-0}"
  local mins body detail
  mins=$(( (down_sec + 59) / 60 ))
  if (( down_sec <= 0 )); then
    detail="Kesinti süresi bilinmiyor (ilk açılış veya kayıt yok)."
  else
    detail="Yaklaşık ${mins} dk kapalıydı (${down_sec}s)."
  fi
  body="$(notify_html_alert "$host" \
    "Sunucu açıldı; servisler başlıyor." \
    "$detail" \
    "DNS 1–3 dk içinde düzelir. Durum: $(notify_escape_html "$(panel_url gateway)")")"
  notify_ensure_dir
  # Her boot ayrı olay: önceki state fail gibi (ok→ok susturulmasın).
  echo fail > "${NOTIFY_STATE_DIR}/boot-lifecycle.state" 2>/dev/null || true
  notify_send_with_transition "boot-lifecycle" "ok" "✅ Pi Gateway · Açıldı" "$body" "HTML"
}

# Asistan sohbeti yeniden aktif — kapanış mesajının çifti
notify_hermes_inbox_up() {
  local host="${1:-$(hostname -s)}"
  local body
  body="$(notify_html_alert "$host" \
    "Sohbet asistanı yeniden aktif." \
    "Kısa kesinti bitti; mesaj gönderebilirsin." \
    "Durum: $(notify_escape_html "$(panel_url gateway)")")"
  notify_ensure_dir
  echo fail > "${NOTIFY_STATE_DIR}/hermes-inbox.state" 2>/dev/null || true
  notify_send_with_transition "hermes-inbox" "ok" "✅ Pi Gateway · Asistan" "$body" "HTML"
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

# HTML: özet → detay → aksiyon → (dipnot) → Sunucu
notify_html_alert() {
  local host="$1"
  local headline="$2"
  local detail="$3"
  local action="${4:-}"
  local footnote="${5:-}"
  local lines
  lines="$(printf '<b>%s</b>' "$(notify_escape_html "$headline")")"
  if [[ -n "$detail" ]]; then
    lines="$(printf '%s\n\n<code>%s</code>' "$lines" "$(notify_escape_html "$detail")")"
  fi
  if [[ -n "$action" ]]; then
    lines="$(printf '%s\n\n<b>Ne yapmalı?</b>\n%s' "$lines" "$action")"
  fi
  if [[ -n "$footnote" ]]; then
    lines="$(printf '%s\n\n<i>%s</i>' "$lines" "$footnote")"
  fi
  if [[ -n "$host" ]]; then
    lines="$(printf '%s\n\n<i>Sunucu: %s</i>' "$lines" "$(notify_escape_html "$host")")"
  fi
  printf '%s' "$lines"
}

notify_dns_fail() {
  local host="$1"
  local details="$2"
  local gateway body esc_gw
  gateway="$(panel_url gateway)"
  esc_gw="$(notify_escape_html "$gateway")"
  body="$(notify_html_alert "$host" \
    "Ev DNS veya çekirdek servisler yanıt vermiyor." \
    "$details" \
    "• Pi güç ve ağ bağlantısını kontrol edin
• Geçici çözüm: router DNS → 8.8.8.8
• Durum: ${esc_gw}")"
  notify_send_with_transition "health-dns" "fail" "⚠️ Pi Gateway · DNS" "$body" "HTML"
}

notify_dns_recovered() {
  local host="$1"
  local body
  body="$(notify_html_alert "$host" \
    "Ev DNS ve çekirdek servisler normale döndü." \
    "Tüm kontroller geçti.")"
  notify_send_with_transition "health-dns" "ok" "✅ Pi Gateway · DNS" "$body" "HTML"
}

notify_optional_warn() {
  local host="$1"
  local details="$2"
  local body
  body="$(notify_html_alert "$host" \
    "Yan servisler kapalı — ev DNS etkilenmez." \
    "$details" \
    "Acil değil. Uygun zamanda ilgili servis loglarına bakın.")"
  notify_send_with_transition "health-optional" "fail" "📋 Pi Gateway · Yan servis" "$body" "HTML"
}

notify_optional_recovered() {
  notify_transition_peek "health-optional" "ok" || return 0
  notify_transition_commit "health-optional" "ok"
}

notify_backup_ok() {
  local stamp="$1"
  local body
  body="$(printf '<b>Yedekleme tamamlandı</b>\n<b>Zaman:</b> %s' \
    "$(notify_escape_html "$stamp")")"
  notify_transition_commit "restic-fail" "ok" 2>/dev/null || true
  notify_telegram "✅ Pi Gateway · Yedek" "$body" "restic-ok" "HTML"
}

notify_backup_fail() {
  local details="$1"
  local body
  body="$(notify_html_alert "$(hostname -s 2>/dev/null || echo pi-gateway)" \
    "Yerel yedekleme başarısız veya atlandı." \
    "$details" \
    "• Veri diski (SSD) takılı ve bağlı mı?
• <code>ENABLE_RESTIC=true</code> ayarı açık mı?
• Pi: <code>journalctl -u pi-gateway-backup -n 30</code>")"
  notify_send_with_transition "restic-fail" "fail" "⚠️ Pi Gateway · Yedek" "$body" "HTML"
}

notify_health_systemd_fail() {
  local host="$1"
  local details="${2:-}"
  local human action body

  if [[ -z "$details" ]]; then
    details="$(
      journalctl -t pi-gateway-health -n 30 --no-pager 2>/dev/null \
        | grep -E ' FAIL ' \
        | tail -5 \
        | sed -E 's/^[^ ]+ [^ ]+ [^ ]+ [^ ]+ //; s/^pi-gateway-health\[[0-9]+\]: FAIL //' \
        | tr '\n' '; ' \
        | sed 's/; $//' || true
    )"
  fi

  human="$(notify_escape_html "$details")"
  human="${human//failures=/Sorunlar: }"
  human="${human//exit_code=1/Kontrol başarısız}"
  human="${human//; /$'\n'• }"
  [[ "$human" == •* ]] || human="• ${human}"

  action="• Pi: <code>journalctl -t pi-gateway-health -n 30</code>
• Durmuş kaplar: <code>docker ps --filter status=exited</code>"
  body="$(notify_html_alert "$host" \
    "Sağlık kontrolü başarısız — DNS veya çekirdek servisler." \
    "$human" \
    "$action")"
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
    "Uzak yedek veya geri yükleme denemesi gecikti — ev DNS etkilenmez." \
    "$details" \
    "Mac: <code>make backup-pull</code>
Deneme: <code>make backup-restore-drill</code>")"
  notify_send_with_transition "health-slo-backup" "fail" "📋 Pi Gateway · Uzak yedek" "$body" "HTML"
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
    "Disk doluluk uyarısı: ${mount}" \
    "$detail" \
    "Pi: <code>df -h ${mount}</code>
Gerekirse log veya eski yedek temizliği.")"
  notify_send_with_transition "$key" "fail" "📋 Pi Gateway · Disk" "$body" "HTML"
}

notify_sd_warn() {
  local host="$1"
  local details="$2"
  local recovered="${3:-0}"
  local headline action
  if [[ "$recovered" == "1" ]]; then
    headline="SD kart / sistem diski hâlâ sorunlu — otomatik kurtarma yetmedi."
    action="• Güvenli kapatıp açın
• SD kart sağlığını kontrol edin
• Uzun vadede SSD’den boot düşünün"
  else
    headline="SD kart salt okunur veya sistem diski yazılamıyor."
    action="• Pi’yi yeniden başlatın
• Tekrar olursa SD kartı değiştirin"
  fi
  local body
  body="$(notify_html_alert "$host" "$headline" "$details" "$action")"
  notify_send_with_transition "sd-health" "fail" "⚠️ Pi Gateway · SD kart" "$body" "HTML"
}

notify_sd_recovered() {
  local host="$1"
  local body
  body="$(notify_html_alert "$host" \
    "Sistem diski salt okunurdu — otomatik kurtarma uygulandı." \
    "Servisler yeniden başlatıldı.")"
  notify_send_with_transition "sd-health" "ok" "✅ Pi Gateway · SD kart" "$body" "HTML"
}

notify_stack_recovered() {
  local host="$1"
  local details="$2"
  local gateway body esc_gw
  gateway="$(panel_url gateway)"
  esc_gw="$(notify_escape_html "$gateway")"
  body="$(notify_html_alert "$host" \
    "Otomatik kurtarma tamamlandı." \
    "$(notify_escape_html "$details")" \
    "Durum: ${esc_gw}")"
  notify_ensure_dir
  # Recover her zaman "ok" — önceki state fail gibi görünsün ki peek açılsın.
  echo fail > "${NOTIFY_STATE_DIR}/stack-recovered.state" 2>/dev/null || true
  notify_send_with_transition "stack-recovered" "ok" "✅ Pi Gateway · Kurtarma" "$body" "HTML"
}

notify_ssd_degraded() {
  local host="$1"
  local details="$2"
  local body
  body="$(notify_html_alert "$host" \
    "Veri diski (SSD) yok — DNS SD karttan devam ediyor." \
    "$details" \
    "Disk takılınca tam servisler otomatik geri yüklenir.")"
  notify_send_with_transition "ssd-degraded" "fail" "⚠️ Pi Gateway · Veri diski" "$body" "HTML"
}

notify_ssd_restored() {
  local host="$1"
  local body
  body="$(notify_html_alert "$host" \
    "Veri diski yeniden bağlandı — tam servisler başlatılıyor." \
    "Kısıtlı moddan çıkılıyor.")"
  notify_send_with_transition "ssd-degraded" "ok" "✅ Pi Gateway · Veri diski" "$body" "HTML"
}

notify_latency_slow() {
  local host="$1"
  local details="$2"
  local body
  body="$(notify_html_alert "$host" \
    "DNS veya panel yanıtı yavaş — hizmet ayakta, gecikme yüksek." \
    "$details" \
    "Durum kartında ms güncellenir. Sürerse Unbound / AdGuard / WAN bakın.")"
  notify_send_with_transition "health-latency" "fail" "📋 Pi Gateway · Gecikme" "$body" "HTML"
}

notify_latency_ok() {
  notify_transition_peek "health-latency" "ok" || return 0
  notify_transition_commit "health-latency" "ok"
}

notify_test() {
  local gateway body
  gateway="$(panel_url gateway)"
  body="$(printf '<b>Bildirim kanalı çalışıyor.</b>\n\n<b>Durum:</b> %s\n<b>Menü:</b> <code>/menu</code>' \
    "$(notify_escape_html "$gateway")")"
  notify_telegram "✅ Pi Gateway · Test" "$body" "test-once" "HTML"
}
