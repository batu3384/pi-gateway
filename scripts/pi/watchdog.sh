#!/usr/bin/env bash
# Pi Gateway watchdog — Hermes cron stdout veya doğrudan bot bildirimi.
# Sorun yok: stderr [SILENT], stdout bos. Sorun var: alert metni (+ isteğe bağlı notify.sh).
# WATCHDOG_NOTIFY_BOT=1 yalnizca Hermes cron kapaliysa; ikisi birlikte cift bildirim.
set -uo pipefail
REMOTE_DIR="${REMOTE_DIR:-/home/${USER}/pi-gateway}"
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

TEMP_MAX="${WATCHDOG_TEMP_MAX:-75}"
DISK_MAX="${WATCHDOG_DISK_MAX:-85}"
AVAIL_MIN_MB="${WATCHDOG_AVAIL_MIN_MB:-800}"
RAM_AVAIL_MIN_MB="${WATCHDOG_RAM_MIN_MB:-300}"
SWAP_MAX_MB="${WATCHDOG_SWAP_MAX_MB:-1500}"
ALERTS=()

if command -v vcgencmd >/dev/null 2>&1; then
  temp="$(vcgencmd measure_temp 2>/dev/null | grep -oE '[0-9]+\.?[0-9]*' || true)"
  if [[ -n "${temp:-}" ]] && awk "BEGIN{exit !($temp > $TEMP_MAX)}"; then
    ALERTS+=("CPU ${temp}°C (eşik ${TEMP_MAX}°C) — throttling riski")
  fi
fi

disk_pct="$(df / | awk 'NR==2{gsub(/%/,""); print $5}')"
disk_avail_mb="$(df -BM / | awk 'NR==2{gsub(/[^0-9]/,""); print $4}')"
if [[ -n "${disk_pct:-}" ]] && (( disk_pct >= DISK_MAX )); then
  ALERTS+=("Disk / doluluk %${disk_pct} (eşik %${DISK_MAX})")
fi
if [[ -n "${disk_avail_mb:-}" ]] && (( disk_avail_mb < AVAIL_MIN_MB )); then
  ALERTS+=("Disk / boş alan ${disk_avail_mb}MB (min ${AVAIL_MIN_MB}MB)")
fi

ram_avail_mb="$(free -m | awk 'NR==2{print $7}')"
if [[ -n "${ram_avail_mb:-}" ]] && (( ram_avail_mb < RAM_AVAIL_MIN_MB )); then
  ALERTS+=("Available RAM ${ram_avail_mb}MB (min ${RAM_AVAIL_MIN_MB}MB)")
fi

failed="$(systemctl list-units --state=failed --no-legend --plain 2>/dev/null | awk '{print $1}' | grep -v '^$' | head -5 | tr '\n' ' ')"
if [[ -n "${failed}" ]]; then
  ALERTS+=("Failed systemd: ${failed}")
fi

exited="$(docker ps -a --filter "status=exited" --filter "status=dead" --filter "status=restarting" \
  --format "{{.Names}} ({{.Status}})" 2>/dev/null | head -5 | tr '\n' '; ')"
if [[ -n "${exited}" ]]; then
  ALERTS+=("Sorunlu container: ${exited}")
fi

unhealthy="$(docker ps --filter "health=unhealthy" --format "{{.Names}}" 2>/dev/null | head -5 | tr '\n' ' ')"
if [[ -n "${unhealthy}" ]]; then
  ALERTS+=("Unhealthy container: ${unhealthy}")
fi

swap_used_mb="$(free -m | awk 'NR==3{print $3}')"
if [[ -n "${swap_used_mb:-}" ]] && (( swap_used_mb > SWAP_MAX_MB )); then
  ALERTS+=("Swap ${swap_used_mb}MB (eşik ${SWAP_MAX_MB}MB)")
fi

if ((${#ALERTS[@]})); then
  COOLDOWN="${WATCHDOG_ALERT_COOLDOWN_SEC:-3600}"
  STAMP="${WATCHDOG_ALERT_STAMP:-/var/lib/pi-gateway/watchdog-last-alert.txt}"
  now="$(date +%s)"
  last="0"
  [[ -f "$STAMP" ]] && last="$(cat "$STAMP" 2>/dev/null || echo 0)"
  if [[ "$last" =~ ^[0-9]+$ ]] && (( now - last < COOLDOWN )); then
    echo "[SILENT] Watchdog cooldown aktif." >&2
    exit 0
  fi
  alert_text=""
  for a in "${ALERTS[@]}"; do
    alert_text+="- ${a}"$'\n'
  done
  if [[ "${WATCHDOG_NOTIFY_BOT:-0}" == "1" ]]; then
    # shellcheck source=../lib/env-file.sh
    source "${SCRIPT_DIR}/../lib/env-file.sh"
    read_remote_dotenv || true
    # shellcheck source=../lib/notify.sh
    source "${SCRIPT_DIR}/../lib/notify.sh"
    host="$(hostname -s 2>/dev/null || echo pi-gateway)"
    esc_alert="$(notify_escape_html "$alert_text")"
    body="$(notify_html_alert "$host" \
      "Sistem gözcüsü metrik eşiği aşıldı." \
      "$esc_alert" \
      "journalctl -u hermes-gateway -n 20 veya docker ps ile doğrulayın." \
      "Saatte en fazla bir hatırlatma.")"
    notify_send_with_transition "watchdog-metrics" "fail" "📋 Pi Gateway · Sistem" "$body" "HTML" || true
  fi
  printf '📋 Pi Gateway · Sistem\n%s\n\nSistem gözcüsü metrik eşiği aşıldı.\n\n%sNe yapmalı?\njournalctl -u hermes-gateway -n 20 veya docker ps ile doğrulayın.\n\nSaatte en fazla bir hatırlatma.\n' \
    "$(date '+%d.%m.%Y %H:%M')" "$alert_text"
  mkdir -p "$(dirname "$STAMP")" 2>/dev/null || true
  echo "$now" >"$STAMP" 2>/dev/null || true
  exit 0
fi

if [[ -f "${WATCHDOG_ALERT_STAMP:-/var/lib/pi-gateway/watchdog-last-alert.txt}" ]]; then
  rm -f "${WATCHDOG_ALERT_STAMP:-/var/lib/pi-gateway/watchdog-last-alert.txt}" 2>/dev/null || true
fi

if [[ "${WATCHDOG_NOTIFY_BOT:-0}" == "1" ]]; then
  source "${SCRIPT_DIR}/../lib/env-file.sh" 2>/dev/null || true
  read_remote_dotenv 2>/dev/null || true
  source "${SCRIPT_DIR}/../lib/notify.sh" 2>/dev/null || true
  notify_transition_peek "watchdog-metrics" "ok" && notify_transition_commit "watchdog-metrics" "ok" || true
fi
echo "[SILENT] Tüm metrikler normal." >&2
