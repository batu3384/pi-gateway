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

notify_send_lock_acquire() {
  notify_ensure_dir
  command -v flock >/dev/null 2>&1 || return 0
  exec {NOTIFY_LOCK_FD}>"${NOTIFY_STATE_DIR}/send.lock" || {
    unset NOTIFY_LOCK_FD
    return 0
  }
  flock -x "$NOTIFY_LOCK_FD" || {
    exec {NOTIFY_LOCK_FD}>&-
    unset NOTIFY_LOCK_FD
    return 1
  }
}

notify_send_lock_release() {
  local fd="${NOTIFY_LOCK_FD:-}"
  [[ -n "$fd" ]] || return 0
  flock -u "$fd" 2>/dev/null || true
  exec {NOTIFY_LOCK_FD}>&-
  unset NOTIFY_LOCK_FD
}

# Health timer her tick — reboot downtime hesabı için.
notify_touch_alive() {
  local now
  notify_ensure_dir
  now="$(date +%s)"
  echo "$now" > "$NOTIFY_LAST_ALIVE_FILE" 2>/dev/null || true
}

# Telegram sesi (kullanıcıya):
#   Başlık: emoji + Net/Profesyonel Türkçe Başlık (Pi Gateway spam yok)
#   Gövde: ne oldu (insan dili). Eng/ops jargon yok (inbox, stack, SLA, P2…).
#   Detay: teknik durum / servis tablosu (HTML bullets). Aksiyon: ne yapmalı.
notify_boot_up() {
  local host="$1"
  local down_sec="${2:-0}"
  local mins body detail gateway
  gateway="$(panel_url gateway)"
  mins=$(( (down_sec + 59) / 60 ))
  if (( down_sec <= 0 )); then
    detail="Sunucu yeniden başlatıldı; DNS ve çekirdek servisler devrede."
  else
    detail="Yaklaşık ${mins} dk kapalı kaldı (${down_sec}s). Servisler devrede."
  fi
  body="$(notify_html_alert "$detail" "" "Durum: $(notify_escape_html "$gateway")")"
  notify_ensure_dir
  # Her boot ayrı olay: önceki state fail gibi (ok→ok susturulmasın).
  echo fail > "${NOTIFY_STATE_DIR}/boot-lifecycle.state" 2>/dev/null || true
  notify_send_with_transition "boot-lifecycle" "ok" "✅ Sistem Başlatıldı" "$body" "HTML"
}

# Asistan sohbeti yeniden aktif — kapanış mesajının çifti
notify_hermes_inbox_up() {
  local host="${1:-$(hostname -s)}"
  local body gateway
  gateway="$(panel_url gateway)"
  body="$(notify_html_alert "Yeni mesajları gönderebilirsiniz." "" "Durum: $(notify_escape_html "$gateway")")"
  notify_ensure_dir
  echo fail > "${NOTIFY_STATE_DIR}/hermes-inbox.state" 2>/dev/null || true
  notify_send_with_transition "hermes-inbox" "ok" "✅ Asistan Sohbeti Aktif" "$body" "HTML"
}

notify_repeat_sec_for() {
  local key="$1"
  case "$key" in
    health-slo-backup) printf '%s' "$NOTIFY_SLO_REPEAT_SEC" ;;
    ssd-usb-flap) printf '%s' "${NOTIFY_USB_FLAP_REPEAT_SEC:-21600}" ;;
    disk-*) printf '%s' "$NOTIFY_DISK_REPEAT_SEC" ;;
    restic-ok) printf '%s' "${NOTIFY_BACKUP_OK_COOLDOWN_SEC:-86400}" ;;
    ibb-hki) printf '%s' "${NOTIFY_IBB_REPEAT_SEC:-21600}" ;;
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
  return 0
}

notify_rate_commit() {
  local key="$1"
  notify_ensure_dir
  date +%s > "${NOTIFY_STATE_DIR}/${key}" 2>/dev/null || true
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
  local body="${4:-}"
  local parse_mode="${5:-}"

  notify_enabled || return 0
  notify_send_lock_acquire || return 0
  if ! notify_transition_peek "$key" "$new_state"; then
    notify_send_lock_release
    return 0
  fi

  local text
  local title_fmt="$title"
  if [[ "$parse_mode" == "HTML" ]]; then
    title_fmt="$(notify_escape_html "$title")"
  fi
  if [[ -n "$body" ]]; then
    text="$(printf '<b>%s</b>\n\n%s' "$title_fmt" "$body")"
  else
    text="$(printf '<b>%s</b>' "$title_fmt")"
  fi
  if notify_send_message "$text" "$parse_mode"; then
    notify_transition_commit "$key" "$new_state"
  fi
  notify_send_lock_release
}

notify_escape_html() {
  local text="$1"
  text="${text//&/\&amp;}"
  text="${text//</\&lt;}"
  text="${text//>/\&gt;}"
  text="${text//\'/\&#39;}"
  printf '%s' "$text"
}

notify_send_message() {
  local text="$1"
  local parse_mode="${2:-}"
  local response=""

  if [[ -n "$parse_mode" ]]; then
    response="$(curl -fsS -X POST "https://api.telegram.org/bot${TELEGRAM_BOT_TOKEN}/sendMessage" \
      -d "chat_id=${TELEGRAM_CHAT_ID}" \
      -d "parse_mode=${parse_mode}" \
      --data-urlencode "text=${text}" \
      -d "disable_web_page_preview=true" 2>&1)" || true
  else
    response="$(curl -fsS -X POST "https://api.telegram.org/bot${TELEGRAM_BOT_TOKEN}/sendMessage" \
    -d "chat_id=${TELEGRAM_CHAT_ID}" \
    --data-urlencode "text=${text}" \
    -d "disable_web_page_preview=true" 2>&1)" || true
  fi

  if [[ -n "$response" ]] && python3 -c \
    'import json,sys; d=json.load(sys.stdin); raise SystemExit(0 if d.get("ok") is True else 1)' \
    <<<"$response" 2>/dev/null; then
    return 0
  fi
  echo "[notify] Telegram gonderilemedi: ${response:-bilinmeyen hata}" >&2
  return 1
}

notify_telegram() {
  local title="$1"
  local body="${2:-}"
  local key="${3:-alert}"
  local parse_mode="${4:-}"
  local cooldown
  cooldown="$(notify_repeat_sec_for "$key")"

  notify_enabled || return 0
  notify_send_lock_acquire || return 0
  if ! notify_rate_ok "$key" "$cooldown"; then
    notify_send_lock_release
    return 0
  fi

  local text
  local title_fmt="$title"
  if [[ "$parse_mode" == "HTML" ]]; then
    title_fmt="$(notify_escape_html "$title")"
  fi
  if [[ -n "$body" ]]; then
    text="$(printf '<b>%s</b>\n\n%s' "$title_fmt" "$body")"
  else
    text="$(printf '<b>%s</b>' "$title_fmt")"
  fi
  if notify_send_message "$text" "$parse_mode"; then
    notify_rate_commit "$key"
  fi
  notify_send_lock_release
}

# HTML: güvenilir raw fragment → (aksiyon) → (dipnot)
notify_html_alert_raw() {
  local detail="${1:-}"
  local action="${2:-}"
  local footnote="${3:-}"
  local lines=""
  if [[ -n "$detail" ]]; then
    lines="$detail"
  fi
  if [[ -n "$action" ]]; then
    if [[ -n "$lines" ]]; then
      lines="$(printf '%s\n\n<b>Ne yapmalı?</b>\n%s' "$lines" "$action")"
    else
      lines="$(printf '<b>Ne yapmalı?</b>\n%s' "$action")"
    fi
  fi
  if [[ -n "$footnote" ]]; then
    if [[ -n "$lines" ]]; then
      lines="$(printf '%s\n\n<i>%s</i>' "$lines" "$footnote")"
    else
      lines="$(printf '<i>%s</i>' "$footnote")"
    fi
  fi
  printf '%s' "$lines"
}

notify_html_alert() {
  local detail="${1:-}"
  local action="${2:-}"
  local footnote="${3:-}"
  notify_html_alert_raw "$(notify_escape_html "$detail")" "$action" "$footnote"
}

notify_dns_fail() {
  local host="$1"
  local details="$2"
  local gateway body esc_gw
  gateway="$(panel_url gateway)"
  esc_gw="$(notify_escape_html "$gateway")"
  body="$(notify_html_alert \
    "$details" \
    "• Pi güç ve ağ bağlantısını kontrol edin
• Geçici çözüm: router DNS → 8.8.8.8" \
    "Durum: ${esc_gw}")"
  notify_send_with_transition "health-dns" "fail" "⚠️ Ev DNS Kesintisi" "$body" "HTML"
}

notify_dns_recovered() {
  local host="$1"
  local gateway body esc_gw
  gateway="$(panel_url gateway)"
  esc_gw="$(notify_escape_html "$gateway")"
  body="$(notify_html_alert \
    "Çekirdek DNS kontrolleri yeniden geçiyor; AdGuard ve Unbound yanıt veriyor." \
    "" \
    "Durum: ${esc_gw}")"
  notify_send_with_transition "health-dns" "ok" "✅ Ev DNS Normale Döndü" "$body" "HTML"
}

notify_optional_warn() {
  local host="$1"
  local details="$2"
  local body
  body="$(notify_html_alert \
    "$details" \
    "• İkincil servis loglarını inceleyin (DNS etkilenmez).")"
  notify_send_with_transition "health-optional" "fail" "📋 İkincil Servis Uyarısı" "$body" "HTML"
}

notify_optional_recovered() {
  notify_send_with_transition \
    "health-optional" "ok" "✅ İkincil Servisler Normal" \
    "Önceki ikincil servis uyarısı sona erdi; kontroller tekrar geçiyor." "HTML"
}

notify_backup_ok() {
  local stamp="$1"
  local body
  body="$(notify_html_alert "Son başarılı yedek zaman damgası: $(notify_escape_html "$stamp").")"
  notify_transition_commit "restic-fail" "ok" 2>/dev/null || true
  notify_telegram "✅ Yedekleme Tamamlandı" "$body" "restic-ok" "HTML"
}

notify_backup_fail() {
  local details="$1"
  local body
  body="$(notify_html_alert \
    "$details" \
    "• Veri diski (SSD) takılı ve bağlı mı?
• <code>ENABLE_RESTIC=true</code> ayarı açık mı?
• Pi: <code>journalctl -u pi-gateway-backup -n 30</code>")"
  notify_send_with_transition "restic-fail" "fail" "⚠️ Yedekleme Başarısız" "$body" "HTML"
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
        | sed -E 's/^[^ ]+ [^ ]+ [^ ]+ //; s/^pi-gateway-health\[[0-9]+\]: FAIL //' \
        | tr '\n' '; ' \
        | sed 's/; $//' || true
    )"
  fi

  human="${details//failures=/Sorunlar: }"
  human="${human//exit_code=1/Kontrol başarısız}"
  human="${human//; /$'\n'• }"
  [[ "$human" == •* ]] || human="• ${human}"

  action="• Pi: <code>journalctl -t pi-gateway-health -n 30</code>
• Durmuş kaplar: <code>docker ps --filter status=exited</code>"
  body="$(notify_html_alert "$human" "$action")"
  notify_send_with_transition "health-systemd" "fail" "⚠️ Sistem Sağlık Uyarısı" "$body" "HTML"
}

notify_health_systemd_ok() {
  notify_send_with_transition \
    "health-systemd" "ok" "✅ Sistem Sağlık Kontrolü Düzeldi" \
    "Önceki çekirdek sağlık uyarısı sona erdi." "HTML"
}

notify_slo_backup() {
  local host="$1"
  local details="$2"
  local body
  body="$(notify_html_alert \
    "Beklenen yedekleme veya geri yükleme aralığı aşıldı; ev DNS etkilenmez. Detay: ${details}" \
    "• Mac: <code>make backup-pull</code>
• Deneme: <code>make backup-restore-drill</code>")"
  notify_send_with_transition "health-slo-backup" "fail" "📋 Uzak Yedek Gecikti" "$body" "HTML"
}

notify_slo_backup_ok() {
  notify_send_with_transition \
    "health-slo-backup" "ok" "✅ Uzak Yedek Güncel" \
    "Yedek ve geri yükleme denemesi yeniden izin verilen aralıkta." "HTML"
}

notify_slo_ops() {
  local host="$1"
  local details="${2:-}"
  local body esc_details
  esc_details="$(notify_escape_html "$details")"
  body="$(notify_html_alert \
    "Bakım ve otomasyon kontrollerinden biri beklenen zamanda tamamlanmadı." \
    "• Ayrıntı: ${esc_details}
• İlgili zamanlayıcı ve servis günlüklerini kontrol edin.")"
  notify_send_with_transition \
    "health-slo-ops" "fail" "⚠️ Operasyon Kontrolü Gecikti" "$body" "HTML"
}

notify_slo_ops_ok() {
  notify_send_with_transition \
    "health-slo-ops" "ok" "✅ Operasyon Kontrolleri Güncel" \
    "Önceki bakım ve otomasyon gecikmesi sona erdi." "HTML"
}

notify_disk_warn() {
  local mount="$1"
  local detail="$2"
  local subject="${3:-Bağlantı noktası: ${mount}}"
  local key="disk-${mount//\//-}"
  local body
  body="$(notify_html_alert \
    "${subject}: ${detail}" \
    "• Pi: <code>df -hP ${mount}</code> · <code>free -m</code>")"
  notify_send_with_transition "$key" "fail" "📋 Disk Doluluk Uyarısı" "$body" "HTML"
}

notify_ssd_usb_flap() {
  local detail="${1:-}"
  local body
  body="$(notify_html_alert \
    "USB/SSD bağlantısı zayıflıyor olabilir. Yazılımsal kurtarma devrede; kablo değişimi gerekmez." \
    "• Detay: $(notify_escape_html "$detail")
• Durum: /ssd · kurtarma: /recover
• journal: <code>journalctl -k -g usb</code>")"
  notify_send_with_transition "ssd-usb-flap" "fail" "⚠️ SSD USB Erken Uyarı" "$body" "HTML"
}

notify_ssd_usb_flap_ok() {
  notify_send_with_transition \
    "ssd-usb-flap" "ok" "✅ SSD USB Stabil" \
    "CRC ve reset sayacı normale döndü." "HTML"
}

notify_restic_offsite_stale() {
  local age="$1"
  local body
  body="$(notify_html_alert \
    "Bulut offsite kopya ${age} gündür güncellenmedi." \
    "• .env: RESTIC_OFFSITE_* kontrol
• Manuel: <code>restic-offsite-copy.sh</code>")"
  notify_send_with_transition "restic-offsite" "fail" "📋 Bulut Yedek Gecikti" "$body" "HTML"
}

notify_restic_offsite_missing() {
  local body
  body="$(notify_html_alert \
    "Bulut offsite kopya hiç yapılmamış (RESTIC_OFFSITE_ENABLED=true)." \
    "• Local backup sonrası offsite copy çalışmalı
• .env: RESTIC_OFFSITE_REPOSITORY + anahtarlar")"
  notify_send_with_transition "restic-offsite" "fail" "📋 Bulut Yedek Eksik" "$body" "HTML"
}

notify_restic_offsite_ok() {
  notify_send_with_transition \
    "restic-offsite" "ok" "✅ Bulut Yedek Güncel" \
    "Offsite restic kopyası yenilendi." "HTML"
}

notify_ssd_post_recovery() {
  local detail="${1:-}"
  local body
  body="$(notify_html_alert \
    "USB kopması sonrası yazılımsal kurtarma tamamlandı." \
    "• $(notify_escape_html "$detail")
• /ssd · /backup ile doğrula")"
  notify_send_with_transition "ssd-post-recovery" "ok" "✅ SSD Olay Raporu" "$body" "HTML"
}

notify_sd_warn() {
  local host="$1"
  local details="$2"
  local recovered="${3:-0}"
  local action
  if [[ "$recovered" == "1" ]]; then
    action="• Otomatik kurtarma yetersiz kaldı; sistemi güvenli yeniden başlatın.
• SD kart sağlığını kontrol edin."
  else
    action="• Pi’yi yeniden başlatın.
• Tekrar ederse SD kartı değiştirin."
  fi
  local body
  body="$(notify_html_alert "$details" "$action")"
  notify_send_with_transition "sd-health" "fail" "⚠️ SD Kart Sağlık Uyarısı" "$body" "HTML"
}

notify_sd_recovered() {
  local host="$1"
  local gateway body esc_gw
  gateway="$(panel_url gateway)"
  esc_gw="$(notify_escape_html "$gateway")"
  body="$(notify_html_alert \
    "Salt okunur mod giderildi; servisler yeniden başlatıldı." \
    "" \
    "Durum: ${esc_gw}")"
  notify_send_with_transition "sd-health" "ok" "✅ Sistem Diski Kurtarıldı" "$body" "HTML"
}

notify_stack_recovered() {
  local host="$1"
  local details="$2"
  local gateway body esc_gw
  gateway="$(panel_url gateway)"
  esc_gw="$(notify_escape_html "$gateway")"
  body="$(notify_html_alert \
    "$details" \
    "" \
    "Durum: ${esc_gw}")"
  notify_ensure_dir
  # Recover her zaman "ok" — önceki state fail gibi görünsün ki peek açılsın.
  echo fail > "${NOTIFY_STATE_DIR}/stack-recovered.state" 2>/dev/null || true
  notify_send_with_transition "stack-recovered" "ok" "✅ Otomatik Kurtarma Tamamlandı" "$body" "HTML"
}

notify_ssd_fail_closed() {
  local host="$1"
  local details="${2:-}"
  local body
  body="$(notify_html_alert \
    "SSD erişilemedi. Korumalı kapatma politikası nedeniyle DNS ve bağlı servisler otomatik olarak kapatıldı." \
    "• SSD/USB güç ve bağlantısını kontrol edin.
• Bağlantı düzeldikten sonra otomatik kurtarma yeniden denenecek." \
    "${details:+Teknik detay: $(notify_escape_html "$details")}")"
  notify_send_with_transition "ssd-degraded" "fail" "⚠️ Veri Diski Koptu — DNS Kapatıldı" "$body" "HTML"
}

notify_ssd_degraded() {
  local host="$1"
  local details="${2:-}"
  if [[ "${DNS_DEGRADED_ON_SSD_LOSS:-true}" != "true" \
    && "${STORAGE_FALLBACK_SD:-false}" != "true" ]]; then
    notify_ssd_fail_closed "$host" "$details"
    return
  fi
  local body
  local detail_text="• <b>DNS & İnternet:</b> Kesintisiz aktif (AdGuard ve Unbound SD karta alındı).
• <b>İkincil Servisler:</b> Veri güvenliği için geçici durduruldu (n8n, paneller).
• <b>Otomatik Kurtarma:</b> Sistem arka planda USB bağlantısını yeniden kurmayı deniyor."

  if [[ -n "$details" && "$details" != *"DNS degraded"* && "$details" != *"Veri diski bağlı değil"* ]]; then
    detail_text="${detail_text}
• <b>Teknik Detay:</b> $(notify_escape_html "$details")"
  fi

  body="$(notify_html_alert_raw \
    "$detail_text" \
    "• Fiziksel müdahale gerekmez; otomatik kurtarma bekleniyor.
• Sorun devam ederse USB bağlantısını kontrol edin.")"
  notify_send_with_transition "ssd-degraded" "fail" "⚠️ Veri Diski (SSD) Koptu — Korumalı Mod" "$body" "HTML"
}

notify_ssd_recovery_failed() {
  local host="$1"
  local details="${2:-}"
  local body
  body="$(notify_html_alert \
    "SSD bağlantısı geri geldi; ancak tüm servislerin sağlığı doğrulanamadı." \
    "• Sistem kısmi çalışıyor olabilir; DNS ve panel durumunu kontrol edin.
• Bir sonraki sağlık döngüsü kurtarmayı yeniden deneyecek." \
    "${details:+Teknik detay: $(notify_escape_html "$details")}")"
  notify_send_with_transition \
    "ssd-degraded" "fail" "⚠️ SSD Kurtarma Tamamlanamadı" "$body" "HTML"
}

notify_ssd_restored() {
  local host="$1"
  local details="${2:-}"
  local gateway esc_gw
  gateway="$(panel_url gateway)"
  esc_gw="$(notify_escape_html "$gateway")"
  local detail_text="• <b>Depolama:</b> SSD (/mnt/ssd) mount edildi, veri dizini senkronize.
• <b>Docker & Servisler:</b> Caddy, n8n, NetAlertX ve izleme panelleri tam kapasite devrede.
• <b>DNS:</b> Normal çalışma düzenine alındı."

  if [[ -n "$details" ]]; then
    detail_text="${detail_text}
• <b>Kurtarma Notu:</b> $(notify_escape_html "$details")"
  fi

  local body
  body="$(notify_html_alert_raw \
    "$detail_text" \
    "" \
    "Durum: ${esc_gw}")"
  notify_send_with_transition "ssd-degraded" "ok" "✅ Veri Diski & Servisler Kurtarıldı" "$body" "HTML"
}

notify_latency_slow() {
  local host="$1"
  local details="$2"
  local body
  body="$(notify_html_alert \
    "Gecikme süresi yükseldi (${details}). Hizmet ayakta." \
    "• Durum kartında ms güncellenir. Sürerse Unbound / AdGuard / WAN bakın.")"
  notify_send_with_transition "health-latency" "fail" "📋 Ağ / DNS Gecikme Uyarısı" "$body" "HTML"
}

notify_latency_ok() {
  notify_send_with_transition \
    "health-latency" "ok" "✅ Gecikme Normale Döndü" \
    "DNS ve panel yanıt süreleri yeniden eşik içinde." "HTML"
}

notify_ibb_hki_warn() {
  local detail="$1"
  local body graf
  graf="$(notify_escape_html "$(notify_panel_url grafana)")"
  body="$(notify_html_alert \
    "İBB açık veri istasyon ölçümü eşik üstü (${detail})." \
    "• Hassas gruplar dışarıda temkinli olsun." \
    "Grafik: ${graf}")"
  notify_send_with_transition "ibb-hki" "fail" "📋 Hava Kalitesi Uyarısı (HKI)" "$body" "HTML"
}

notify_ibb_hki_ok() {
  local body
  body="$(notify_html_alert "Ölçüm yeniden iyi bandı içinde.")"
  notify_send_with_transition "ibb-hki" "ok" "✅ Hava Kalitesi Normale Döndü" "$body" "HTML"
}

notify_test() {
  local gateway body
  gateway="$(panel_url gateway)"
  body="$(notify_html_alert "Bildirim kanalı ve servisler aktif." "" "Durum: $(notify_escape_html "$gateway")")"
  notify_telegram "✅ Bildirim Testi" "$body" "test-once" "HTML"
}
