#!/usr/bin/env bash
# Tek komut read-only Pi Gateway durum fotoğrafı (Jarvis tanılama aracı).
# Sıfır gizli değer, sıfır yan etki — yalnızca anlık sistem özeti üretir.
set -euo pipefail
export PATH="/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin:${PATH:-}"

REMOTE_DIR="${REMOTE_DIR:-/home/${USER:-pi}/pi-gateway}"
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
if [[ -f "${SCRIPT_DIR}/../lib/env-file.sh" ]]; then
  # shellcheck source=../lib/env-file.sh
  source "${SCRIPT_DIR}/../lib/env-file.sh"
  read_remote_dotenv || true
fi

now="$(date -Iseconds)"
host_name="$(hostname -s 2>/dev/null || echo pi)"
uptime_str="$(uptime -p 2>/dev/null || uptime)"
load_str="$(awk '{print $1, $2, $3}' /proc/loadavg 2>/dev/null || echo '?')"

# RAM & Swap
mem_line="$(awk '
  /^MemTotal:/ {t=$2}
  /^MemAvailable:/ {a=$2}
  /^SwapTotal:/ {st=$2}
  /^SwapFree:/ {sf=$2}
  END {
    if (t>0) {
      used_pct=int((t-a)*100/t);
      printf "used=%d%% avail=%dMiB total=%dMiB swap=%d/%dMiB", used_pct, int(a/1024), int(t/1024), int((st-sf)/1024), int(st/1024)
    } else { print "unknown" }
  }' /proc/meminfo 2>/dev/null || echo "unknown")"

# CPU temp & throttle
temp_c="?"
if [[ -r /sys/class/thermal/thermal_zone0/temp ]]; then
  temp_c="$(LC_ALL=C awk '{printf "%.1fC", $1/1000}' /sys/class/thermal/thermal_zone0/temp 2>/dev/null || echo '?')"
fi
throttle="n/a"
if command -v vcgencmd >/dev/null 2>&1; then
  throttle="$(vcgencmd get_throttled 2>/dev/null | cut -d= -f2 || echo 'n/a')"
fi

# Disks & SSD SMART
sd_df="$(LC_ALL=C df -hP / 2>/dev/null | awk 'NR==2 {printf "%s/%s (%s)", $3, $2, $5}')"
ssd_df="unmounted"
ssd_dev=""
if mountpoint -q /mnt/ssd 2>/dev/null; then
  ssd_df="$(LC_ALL=C df -hP /mnt/ssd 2>/dev/null | awk 'NR==2 {printf "%s/%s (%s)", $3, $2, $5}')"
  ssd_src="$(findmnt -n -o SOURCE /mnt/ssd 2>/dev/null || true)"
  ssd_dev="$(lsblk -no PKNAME "$ssd_src" 2>/dev/null | head -1 || true)"
fi
smart_line="n/a"
if [[ -n "$ssd_dev" ]] && command -v smartctl >/dev/null 2>&1; then
  smart_raw="$(sudo -n smartctl -H -A -d sat "/dev/${ssd_dev}" 2>/dev/null || sudo -n smartctl -H -A "/dev/${ssd_dev}" 2>/dev/null || true)"
  if [[ -n "$smart_raw" ]]; then
    sh_ok="$(printf '%s\n' "$smart_raw" | awk -F: '/SMART overall-health|SMART Health Status/{gsub(/^ +/,"",$2); print $2; exit}')"
    sh_crc="$(printf '%s\n' "$smart_raw" | awk '/UDMA_CRC_Error_Count/{print $10; exit}')"
    sh_temp="$(printf '%s\n' "$smart_raw" | awk '/Temperature_Celsius/{print $10; exit}')"
    smart_line="dev=/dev/${ssd_dev} health=${sh_ok:-?} temp=${sh_temp:-?}C crc=${sh_crc:-?}"
  fi
fi

# Containers
containers_ok=0
containers_bad=()
if command -v docker >/dev/null 2>&1; then
  while IFS='|' read -r cname cstatus; do
    [[ -n "$cname" ]] || continue
    if [[ "$cstatus" == Up* && "$cstatus" != *unhealthy* && "$cstatus" != *Restarting* ]]; then
      containers_ok=$((containers_ok + 1))
    else
      containers_bad+=("${cname}(${cstatus})")
    fi
  done < <(docker ps -a --format '{{.Names}}|{{.Status}}' 2>/dev/null | sort)
fi

# Systemd failed & OpenBot
sys_failed="$(systemctl --failed --no-legend --plain 2>/dev/null | awk '{print $1}' | paste -sd, - || true)"
ob_state="$(systemctl is-active openbot.service 2>/dev/null || echo inactive)"
ob_mem="$(systemctl show -p MemoryCurrent --value openbot.service 2>/dev/null | awk '{if ($1 ~ /^[0-9]+$/) printf "%dMiB", int($1/1048576); else print "?"}' || echo '?')"

# OOM events in last 24h
oom_24h="$(journalctl -k --since '24 hours ago' --no-pager 2>/dev/null | grep -ciE 'out of memory|oom-killer|killed process' || true)"

# DNS :53 & Unbound :5335
dns53="fail"
if command -v dig >/dev/null 2>&1; then
  if dig +time=2 +tries=1 @127.0.0.1 -p 53 "gateway.${LAN_DOMAIN:-home}" A 2>/dev/null | grep -q 'status: NOERROR'; then
    dns53="ok"
  fi
  dns5335="fail"
  if dig +time=3 +tries=1 @127.0.0.1 -p 5335 cloudflare.com A 2>/dev/null | grep -q 'status: NOERROR'; then
    dns5335="ok"
  fi
else
  dns5335="n/a"
fi

# Backups & state.json summary
state_summary=""
if [[ -f /var/lib/pi-gateway/public/state.json ]]; then
  state_summary="$(python3 - /var/lib/pi-gateway/public/state.json <<'PY' 2>/dev/null || true
import json, sys
d = json.loads(open(sys.argv[1], encoding="utf-8").read())
print(
    f"degraded={d.get('storage_degraded', '?')} "
    f"offsite_age={d.get('offsite_backup_age_days', '?')}d "
    f"drill_age={d.get('backup_restore_drill_age_days', '?')}d "
    f"drill_fail={d.get('backup_restore_drill_failed', '?')} "
    f"dns_ms={d.get('dns_latency_ms', '?')} "
    f"isp={d.get('isp_download_mbps', '?')}Mbps "
    f"agh_block={d.get('adguard_blocked_pct', '?')}%"
)
PY
)"
fi

# Tailscale
ts_state="off"
if command -v tailscale >/dev/null 2>&1; then
  ts_state="$(tailscale status --json 2>/dev/null | python3 -c 'import json,sys; d=json.load(sys.stdin); print(d.get("BackendState","?"))' 2>/dev/null || echo 'err')"
fi

cat <<EOF
=== Pi Gateway Snapshot (${host_name} @ ${now}) ===
Uptime:     ${uptime_str} | load: ${load_str}
Memory:     ${mem_line}
Thermal:    ${temp_c} | throttled=${throttle} | oom_24h=${oom_24h:-0}
Disks:      SD=${sd_df:-?} | SSD=${ssd_df}
SMART:      ${smart_line}
Containers: ok=${containers_ok} bad=${#containers_bad[@]}${containers_bad[*]:+ (${containers_bad[*]})}
Systemd:    failed=${sys_failed:-none} | openbot=${ob_state} (${ob_mem})
DNS:        adguard:53=${dns53} | unbound:5335=${dns5335}
Tailscale:  ${ts_state}
State:      ${state_summary:-unavailable}
EOF
