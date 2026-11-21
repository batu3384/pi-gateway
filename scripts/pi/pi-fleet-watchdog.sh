#!/usr/bin/env bash
# Sıfır-token filo bekçisi. Sağlıklıysa LLM yok; eşik/servis/konteyner/OOM/rutin bozuksa Jarvis'e bir uyarı.
set -euo pipefail
REMOTE_DIR="${REMOTE_DIR:-/home/${USER:-pi}/pi-gateway}"
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
if [[ -f "${SCRIPT_DIR}/../lib/env-file.sh" ]]; then
  # shellcheck source=../lib/env-file.sh
  source "${SCRIPT_DIR}/../lib/env-file.sh"
  read_remote_dotenv || true
fi
if [[ -f "${SCRIPT_DIR}/../lib/openbot-paths.sh" ]]; then
  # shellcheck source=../lib/openbot-paths.sh
  source "${SCRIPT_DIR}/../lib/openbot-paths.sh"
  FLEET="${OPENBOT_FLEET_ROOT:-$(openbot_data_root)/fleet}"
  OB_DB="$(openbot_db_path)"
else
  FLEET="${OPENBOT_FLEET_ROOT:-/mnt/ssd/openbot-native/fleet}"
  OB_DB="/mnt/ssd/openbot-native/config/OpenBot/openbot.db"
fi
HB="${FLEET}/jarvis/watchdog-heartbeat.txt"
STATE="${FLEET}/jarvis/.watchdog-state"
LOG="${FLEET}/jarvis/watchdog.log"
ROTATE_STAMP="${FLEET}/jarvis/.last-shared-rotate"
COOLDOWN_SEC="${WATCHDOG_COOLDOWN_SEC:-1800}"
RAM_MIN_KB=$((350 * 1024))
TEMP_MAX=75000
DISK_MAX=85

mkdir -p "${FLEET}/jarvis"
if [[ -f "$LOG" ]] && [[ "$(wc -l <"$LOG" 2>/dev/null || echo 0)" -gt 500 ]]; then
  tail -n 300 "$LOG" >"${LOG}.tmp" && mv -f "${LOG}.tmp" "$LOG"
fi

# Günde bir kez shared/*.md rolling arşivleme (sıfır LLM, non-fatal)
now_epoch="$(date +%s)"
last_rot="$(cat "$ROTATE_STAMP" 2>/dev/null || echo 0)"
if [[ ! "$last_rot" =~ ^[0-9]+$ ]] || (( now_epoch - last_rot >= 86400 )); then
  rot_bin="${SCRIPT_DIR}/fleet-shared-rotate.sh"
  [[ -x "$rot_bin" ]] || rot_bin="${REMOTE_DIR}/scripts/pi/fleet-shared-rotate.sh"
  if [[ -x "$rot_bin" ]]; then
    OPENBOT_FLEET_ROOT="$FLEET" bash "$rot_bin" >>"$LOG" 2>&1 || true
    printf '%s\n' "$now_epoch" >"$ROTATE_STAMP" 2>/dev/null || true
  fi
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

if command -v vcgencmd >/dev/null 2>&1; then
  thr_hex="$(vcgencmd get_throttled 2>/dev/null | cut -d= -f2 || echo '0x0')"
  if [[ "$thr_hex" =~ ^0x[0-9a-fA-F]+$ ]]; then
    thr_now=$(( thr_hex & 0x7 ))
    if (( thr_now != 0 )); then
      problems+=("Pi throttle aktif (${thr_hex})")
    fi
  fi
fi

df_targets=(/)
if mountpoint -q /mnt/ssd 2>/dev/null; then
  df_targets+=(/mnt/ssd)
fi
while read -r mount pct; do
  [[ -n "${pct:-}" ]] || continue
  problems+=("disk ${mount} %${pct} > ${DISK_MAX}")
done < <(df -P "${df_targets[@]}" 2>/dev/null | awk -v max="$DISK_MAX" 'NR>1 {gsub(/%/,"",$5); if ($5+0>max) print $6, $5}')

# Aktif stack konteynerlerinin tamamı (running + healthy)
containers=(adguard unbound glance gateway-state)
[[ "${ENABLE_CADDY:-true}" == "true" ]] && containers+=(caddy)
[[ "${ENABLE_GATUS:-true}" == "true" ]] && containers+=(gatus)
[[ "${ENABLE_DOZZLE:-true}" == "true" ]] && containers+=(dozzle docker-socket-proxy)
[[ "${ENABLE_MONITORING:-true}" == "true" ]] && containers+=(victoriametrics grafana node-exporter)
[[ "${ENABLE_NETALERTX:-true}" == "true" ]] && containers+=(netalertx)
[[ "${ENABLE_CROWDSEC:-true}" == "true" ]] && containers+=(crowdsec)
[[ "${ENABLE_N8N:-false}" == "true" ]] && containers+=(n8n)

for c in "${containers[@]}"; do
  st="$(docker inspect -f '{{.State.Status}}|{{if .State.Health}}{{.State.Health.Status}}{{else}}none{{end}}' "$c" 2>/dev/null || echo 'missing|none')"
  c_state="${st%%|*}"
  c_health="${st##*|}"
  if [[ "$c_state" != "running" ]]; then
    problems+=("container ${c} ${c_state}")
  elif [[ "$c_health" == "unhealthy" ]]; then
    problems+=("container ${c} unhealthy")
  fi
done

if command -v dig >/dev/null 2>&1; then
  if ! dig +time=2 +tries=1 @127.0.0.1 -p 53 "gateway.${LAN_DOMAIN:-home}" A 2>/dev/null | grep -q 'status: NOERROR'; then
    problems+=("DNS :53 yanıt vermiyor")
  fi
fi

if ! systemctl is-active --quiet openbot.service 2>/dev/null; then
  problems+=("openbot.service aktif değil")
fi

failed_units="$(systemctl --failed --no-legend --plain 2>/dev/null | awk '/^(pi-gateway-|pi-ssd-|pi-data-|openbot)/ {print $1}' | paste -sd, - || true)"
if [[ -n "$failed_units" ]]; then
  problems+=("failed systemd: ${failed_units}")
fi

# Son 10 dakikada OOM killer olayı
oom_recent="$(journalctl -k --since '10 minutes ago' --no-pager 2>/dev/null | grep -ciE 'out of memory|oom-killer|killed process' || true)"
if [[ "${oom_recent:-0}" -gt 0 ]]; then
  problems+=("OOM killer son 10dk (${oom_recent} olay)")
fi

# Son 20 dakikada başarısız OpenBot rutini (sessiz rutin arızası körlüğünü önler)
if [[ -f "$OB_DB" ]] && command -v python3 >/dev/null 2>&1; then
  failed_routines="$(python3 - "$OB_DB" <<'PY' 2>/dev/null || true
import sqlite3, sys
con = sqlite3.connect(f"file:{sys.argv[1]}?mode=ro", uri=True)
rows = con.execute("""
    select distinct ar.name, substr(coalesce(rr.error, ''), 1, 80)
    from projection_routine_runs rr
    join projection_agent_routines ar on ar.routine_id = rr.routine_id
    where rr.status='failed'
      and datetime(rr.created_at) >= datetime('now', '-20 minutes')
    limit 5
""").fetchall()
con.close()
for name, err in rows:
    print(f"{name}: {err}" if err else name)
PY
)"
  while IFS= read -r fr; do
    [[ -n "$fr" ]] || continue
    problems+=("OpenBot rutin hatası: ${fr}")
  done <<<"$failed_routines"
fi

stamp="$(date -Is)"
if [[ ${#problems[@]} -eq 0 ]]; then
  rm -f "$STATE" 2>/dev/null || true
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
