#!/usr/bin/env bash
# Sıfır-token filo bekçisi. Sağlıklıysa LLM yok; eşik/servis bozuksa Jarvis'e bir uyarı.
set -euo pipefail
REMOTE_DIR="${REMOTE_DIR:-/home/${USER:-pi}/pi-gateway}"
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
if [[ -f "${SCRIPT_DIR}/../lib/env-file.sh" ]]; then
  # shellcheck source=../lib/env-file.sh
  source "${SCRIPT_DIR}/../lib/env-file.sh"
  read_remote_dotenv || true
fi
FLEET="${OPENBOT_FLEET_ROOT:-/mnt/ssd/openbot-native/fleet}"
HB="${FLEET}/jarvis/watchdog-heartbeat.txt"
STATE="${FLEET}/jarvis/.watchdog-state"
LOG="${FLEET}/jarvis/watchdog.log"
COOLDOWN_SEC="${WATCHDOG_COOLDOWN_SEC:-1800}"
RAM_MIN_KB=$((350 * 1024))
TEMP_MAX=75000
DISK_MAX=85

mkdir -p "${FLEET}/jarvis"
if [[ -f "$LOG" ]] && [[ "$(wc -l <"$LOG" 2>/dev/null || echo 0)" -gt 500 ]]; then
  tail -n 300 "$LOG" >"${LOG}.tmp" && mv -f "${LOG}.tmp" "$LOG"
fi
problems=()

mem_kb="$(awk '/^MemAvailable:/ {print $2}' /proc/meminfo 2>/dev/null || echo 0)"
if [[ "${mem_kb:-0}" -lt "$RAM_MIN_KB" ]]; then
  problems+=("RAM available $((mem_kb / 1024))MB < 350MB")
fi

temp="$(cat /sys/class/thermal/thermal_zone0/temp 2>/dev/null || echo 0)"
if [[ "${temp:-0}" -ge "$TEMP_MAX" ]]; then
  problems+=("CPU $((temp / 1000))C >= 75C")
fi

while read -r mount pct; do
  [[ -n "${pct:-}" ]] || continue
  problems+=("disk ${mount} %${pct} > ${DISK_MAX}")
done < <(df -P / /mnt/ssd 2>/dev/null | awk -v max="$DISK_MAX" 'NR>1 {gsub(/%/,"",$5); if ($5+0>max) print $6, $5}')

for c in adguard unbound caddy; do
  st="$(docker inspect -f '{{.State.Status}}' "$c" 2>/dev/null || echo missing)"
  if [[ "$st" != "running" ]]; then
    problems+=("container ${c} ${st}")
  fi
done

stamp="$(date -Is)"
if [[ ${#problems[@]} -eq 0 ]]; then
  printf '%s\n' "$stamp" >"$HB"
  exit 0
fi

sig="$(printf '%s\n' "${problems[@]}" | sha256sum | awk '{print $1}')"
now="$(date +%s)"
if [[ -f "$STATE" ]]; then
  prev_sig="$(awk 'NR==1 {print $1}' "$STATE")"
  prev_ts="$(awk 'NR==1 {print $2}' "$STATE")"
  if [[ "$prev_sig" == "$sig" && -n "${prev_ts:-}" ]] && (( now - prev_ts < COOLDOWN_SEC )); then
    printf '%s cooldown %s\n' "$stamp" "$sig" >>"$LOG"
    exit 0
  fi
fi

body="Heimdall · bekçi
Eşik aşıldı

$(printf -- '- %s\n' "${problems[@]}")

Sonraki: tanı yaz. Konteyneri yeniden başlatma. Özeti shared/system_health.md dosyasına aynı kartla işle."

printf '%s\n' "$stamp alert" >>"$LOG"
_js="${REMOTE_DIR}/scripts/pi/jarvis-send.sh"
if REMOTE_DIR="$REMOTE_DIR" \
  bash "$_js" "$body" >>"$LOG" 2>&1; then
  printf '%s %s\n' "$sig" "$now" >"$STATE"
else
  printf '%s jarvis-send fail\n' "$stamp" >>"$LOG"
  exit 1
fi
