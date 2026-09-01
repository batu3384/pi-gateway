#!/usr/bin/env bash
# Prometheus textfile + JSON gateway state (health timer / make status)
set -euo pipefail
REMOTE_DIR="${REMOTE_DIR:-/home/${USER}/pi-gateway}"
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
METRICS_DIR="${PI_GATEWAY_METRICS_DIR:-/var/lib/pi-gateway/metrics}"
METRICS_FILE="${METRICS_DIR}/pi_gateway.prom"
STATE_JSON="${PI_GATEWAY_STATE_JSON:-/var/lib/pi-gateway/state.json}"
OFFSITE_MARKER="${OFFSITE_MARKER:-/var/lib/pi-gateway/last-offsite-backup}"
DRILL_MARKER="${DRILL_MARKER:-/var/lib/pi-gateway/last-backup-restore-drill}"
DRILL_FAILURE_MARKER="${DRILL_FAILURE_MARKER:-/var/lib/pi-gateway/last-backup-restore-drill-failure}"
OFFSITE_COPY_MARKER="${OFFSITE_COPY_MARKER:-/var/lib/pi-gateway/last-restic-offsite-copy}"
COVERAGE_STATE_PATH="${ADGUARD_DNS_COVERAGE_STATE_PATH:-/var/lib/pi-gateway/dns-coverage-state.json}"
COVERAGE_MAX_AGE_SEC="${ADGUARD_DNS_COVERAGE_STATE_MAX_AGE_SEC:-600}"
[[ "$COVERAGE_MAX_AGE_SEC" =~ ^[0-9]+$ ]] || COVERAGE_MAX_AGE_SEC=600
# shellcheck source=../lib/env-file.sh
source "$SCRIPT_DIR/../lib/env-file.sh"
read_remote_dotenv || { echo "[export-state] HATA: .env dotenv parser hatasi" >&2; exit 1; }
STATE_OWNER="${PI_USER:-${SUDO_USER:-${USER:-pi}}}"
# shellcheck source=../lib/stack-health.sh
source "$SCRIPT_DIR/../lib/stack-health.sh"

run_as_needed() {
  if [[ "$(id -u)" -eq 0 ]]; then
    "$@"
  else
    sudo "$@"
  fi
}

usage_pct() {
  local mount="$1"
  df "$mount" 2>/dev/null | awk 'NR==2 {gsub(/%/,""); print $5}' || echo ""
}

file_age_days() {
  local path="$1"
  [[ -f "$path" ]] || { echo -1; return 0; }
  python3 -c "import os,time; print(int((time.time()-os.path.getmtime('$path'))//86400))"
}

degraded=0
storage_degraded && degraded=1
ssd_ok=0
if declare -F ssd_mount_healthy >/dev/null 2>&1; then
  ssd_mount_healthy && ssd_ok=1
elif mountpoint -q /mnt/ssd 2>/dev/null; then
  ssd_ok=1
fi
docker_ssd=0
if [[ "${ENABLE_DOCKER_SSD:-false}" == "true" ]] && docker_ssd_root_ok; then
  docker_ssd=1
fi
root_pct="$(usage_pct /)"
ssd_pct="$(usage_pct /mnt/ssd)"
offsite_age="$(file_age_days "$OFFSITE_MARKER")"
drill_age="$(file_age_days "$DRILL_MARKER")"
drill_failed=0
if [[ -f "$DRILL_FAILURE_MARKER" ]] \
  && { [[ ! -f "$DRILL_MARKER" ]] || [[ "$DRILL_FAILURE_MARKER" -nt "$DRILL_MARKER" ]]; }; then
  drill_failed=1
fi
offsite_copy_age="$(file_age_days "$OFFSITE_COPY_MARKER")"
ts="$(date -Iseconds)"

tmp="$(mktemp)"
cat >"$tmp" <<EOF
# HELP pi_gateway_storage_degraded 1 when core-dns degraded mode is active
# TYPE pi_gateway_storage_degraded gauge
pi_gateway_storage_degraded ${degraded}
# HELP pi_gateway_ssd_mount_healthy 1 when SSD mount passes write probe
# TYPE pi_gateway_ssd_mount_healthy gauge
pi_gateway_ssd_mount_healthy ${ssd_ok}
# HELP pi_gateway_docker_root_on_ssd 1 when Docker data-root matches DOCKER_SSD_ROOT
# TYPE pi_gateway_docker_root_on_ssd gauge
pi_gateway_docker_root_on_ssd ${docker_ssd}
# HELP pi_gateway_root_usage_percent SD root filesystem usage percent
# TYPE pi_gateway_root_usage_percent gauge
pi_gateway_root_usage_percent ${root_pct:-0}
# HELP pi_gateway_ssd_usage_percent SSD mount usage percent (-1 if unmounted)
# TYPE pi_gateway_ssd_usage_percent gauge
pi_gateway_ssd_usage_percent ${ssd_pct:--1}
# HELP pi_gateway_offsite_backup_age_days Days since last Mac backup-pull stamp on Pi (-1 missing)
# TYPE pi_gateway_offsite_backup_age_days gauge
pi_gateway_offsite_backup_age_days ${offsite_age}
# HELP pi_gateway_backup_restore_drill_age_days Days since last restore drill (-1 missing)
# TYPE pi_gateway_backup_restore_drill_age_days gauge
pi_gateway_backup_restore_drill_age_days ${drill_age}
# HELP pi_gateway_backup_restore_drill_failed 1 when latest restore drill failed
# TYPE pi_gateway_backup_restore_drill_failed gauge
pi_gateway_backup_restore_drill_failed ${drill_failed}
# HELP pi_gateway_restic_offsite_copy_age_days Days since last B2/R2 copy (-1 missing/disabled)
# TYPE pi_gateway_restic_offsite_copy_age_days gauge
pi_gateway_restic_offsite_copy_age_days ${offsite_copy_age}
EOF

PROBES_PY="${SCRIPT_DIR}/../lib/gateway-probes.py"
[[ -f "$PROBES_PY" ]] || PROBES_PY="${REMOTE_DIR}/scripts/lib/gateway-probes.py"
probe_json="{}"
if [[ -f "$PROBES_PY" ]]; then
  probe_out="$(REMOTE_DIR="$REMOTE_DIR" python3 "$PROBES_PY" 2>/dev/null || true)"
  if [[ -n "$probe_out" ]]; then
    probe_prom="$(printf '%s\n' "$probe_out" | sed '/^{/,$d')"
    probe_json="$(printf '%s\n' "$probe_out" | sed -n '/^{/,$p')"
    [[ -n "$probe_prom" ]] && printf '%s\n' "$probe_prom" >>"$tmp"
  fi
fi
python3 - "$COVERAGE_STATE_PATH" "$COVERAGE_MAX_AGE_SEC" >>"$tmp" <<'PY'
import json
import sys
import time
from datetime import datetime

path, max_age = sys.argv[1], int(sys.argv[2])
state = {}
try:
    with open(path, encoding="utf-8") as fh:
        state = json.load(fh)
except (OSError, TypeError, ValueError, json.JSONDecodeError):
    pass

status_map = {"off": 0, "ok": 1, "warn": 2, "fail": 3, "unknown": 4}
status = "unknown"
age = -1
try:
    age = max(0, int(time.time() - datetime.fromisoformat(
        str(state["ts"]).replace("Z", "+00:00")
    ).timestamp()))
    if age <= max_age:
        status = str(state.get("status", "unknown"))
except (KeyError, TypeError, ValueError):
    pass
valid = status in status_map and age >= 0 and age <= max_age
if not valid:
    status = "unknown"

def number(key, default):
    if not valid:
        return default
    try:
        return int(state.get(key, default))
    except (TypeError, ValueError):
        return default

print("# HELP pi_gateway_dns_coverage_percent Active devices verified using Pi DNS (-1 unknown)")
print("# TYPE pi_gateway_dns_coverage_percent gauge")
print(f"pi_gateway_dns_coverage_percent {number('coverage_percent', -1)}")
print("# HELP pi_gateway_dns_coverage_status 0 off, 1 ok, 2 warn, 3 fail, 4 unknown")
print("# TYPE pi_gateway_dns_coverage_status gauge")
print(f"pi_gateway_dns_coverage_status {status_map[status]}")
print("# HELP pi_gateway_dns_coverage_active_devices Active devices in coverage denominator")
print("# TYPE pi_gateway_dns_coverage_active_devices gauge")
print(f"pi_gateway_dns_coverage_active_devices {number('active_devices', -1)}")
print("# HELP pi_gateway_dns_coverage_using_pi_dns Devices verified using Pi DNS")
print("# TYPE pi_gateway_dns_coverage_using_pi_dns gauge")
print(f"pi_gateway_dns_coverage_using_pi_dns {number('using_pi_dns', -1)}")
print("# HELP pi_gateway_dns_coverage_protocol_unknown 1 when query protocol is not exposed by AdGuard API")
print("# TYPE pi_gateway_dns_coverage_protocol_unknown gauge")
print(f"pi_gateway_dns_coverage_protocol_unknown {number('protocol_unknown', -1)}")
print("# HELP pi_gateway_dns_coverage_state_age_seconds Age of DNS coverage evidence (-1 unknown)")
print("# TYPE pi_gateway_dns_coverage_state_age_seconds gauge")
print(f"pi_gateway_dns_coverage_state_age_seconds {age if valid else -1}")
PY
rdnss_configured=0
if systemctl is-active --quiet radvd 2>/dev/null \
  && grep -Eq '^[[:space:]]*AdvRDNSSLifetime[[:space:]]+0([[:space:];]|$)' \
    /etc/radvd.conf 2>/dev/null; then
  rdnss_configured=1
fi
cat >>"$tmp" <<EOF
# HELP pi_gateway_ipv6_rdnss_configured 1 when radvd advertises Pi RDNSS and withdraws modem lifetime
# TYPE pi_gateway_ipv6_rdnss_configured gauge
pi_gateway_ipv6_rdnss_configured ${rdnss_configured}
EOF

run_as_needed mkdir -p "$METRICS_DIR" "$(dirname "$STATE_JSON")" 2>/dev/null || true
if [[ "$(id -u)" -eq 0 ]]; then
  install -m 644 "$tmp" "$METRICS_FILE"
else
  run_as_needed install -m 644 "$tmp" "$METRICS_FILE"
fi
rm -f "$tmp"

json_tmp="$(mktemp)"
python3 - "$json_tmp" "$STATE_JSON" "$ts" "$degraded" "$ssd_ok" "$docker_ssd" "${root_pct:-}" "${ssd_pct:-}" \
  "$offsite_age" "$drill_age" "$offsite_copy_age" "$probe_json" "$COVERAGE_STATE_PATH" "$COVERAGE_MAX_AGE_SEC" \
  "$rdnss_configured" "$drill_failed" <<'PY'
import json, sys
import time
from datetime import datetime
tmp, path = sys.argv[1], sys.argv[2]
extra = {}
raw = sys.argv[12] if len(sys.argv) > 12 else "{}"
try:
    extra = json.loads(raw) if raw.strip() else {}
except json.JSONDecodeError:
    extra = {}
coverage = {}
try:
    with open(sys.argv[13], encoding="utf-8") as fh:
        coverage = json.load(fh)
except (OSError, TypeError, ValueError, json.JSONDecodeError):
    coverage = {}
coverage_status = "unknown"
coverage_age = -1
try:
    coverage_age = max(0, int(time.time() - datetime.fromisoformat(
        str(coverage["ts"]).replace("Z", "+00:00")
    ).timestamp()))
    if coverage_age <= int(sys.argv[14]):
        coverage_status = str(coverage.get("status", "unknown"))
except (KeyError, TypeError, ValueError):
    coverage_age = -1
if coverage_status not in {"off", "ok", "warn", "fail"}:
    coverage_status = "unknown"
data = {
    "ts": sys.argv[3],
    "storage_degraded": int(sys.argv[4]),
    "ssd_mount_healthy": int(sys.argv[5]),
    "docker_root_on_ssd": int(sys.argv[6]),
    "root_usage_pct": int(sys.argv[7] or 0),
    "ssd_usage_pct": int(sys.argv[8]) if sys.argv[8] else None,
    "offsite_backup_age_days": int(sys.argv[9]),
    "backup_restore_drill_age_days": int(sys.argv[10]),
    "restic_offsite_copy_age_days": int(sys.argv[11]),
    "dns_coverage_status": coverage_status,
    "dns_coverage_state_age_seconds": coverage_age,
    "ipv6_rdnss_configured": int(sys.argv[15]),
    "backup_restore_drill_failed": int(sys.argv[16]),
}
if coverage_status != "unknown":
    data["dns_coverage_percent"] = int(coverage.get("coverage_percent", -1))
    data["dns_coverage_active_devices"] = int(coverage.get("active_devices", -1))
    data["dns_coverage_using_pi_dns"] = int(coverage.get("using_pi_dns", -1))
    data["dns_coverage_protocol_unknown"] = int(bool(coverage.get("protocol_unknown", False)))
if isinstance(extra, dict):
    for k in ("dns_latency_ms", "panel_latency_ms", "hosts_online", "who_home"):
        if k in extra:
            data[k] = extra[k]
with open(tmp, "w", encoding="utf-8") as f:
    json.dump(data, f, indent=2)
    f.write("\n")
PY
if [[ "$(id -u)" -eq 0 ]]; then
  install -m 644 "$json_tmp" "$STATE_JSON"
else
  run_as_needed install -m 644 "$json_tmp" "$STATE_JSON"
fi
rm -f "$json_tmp"
if [[ "$(id -u)" -eq 0 ]]; then
  chown "${STATE_OWNER}:${STATE_OWNER}" "$STATE_JSON" "$METRICS_FILE" 2>/dev/null || true
else
  run_as_needed chown "${STATE_OWNER}:${STATE_OWNER}" "$STATE_JSON" "$METRICS_FILE" 2>/dev/null || true
fi
_agh_export="${SCRIPT_DIR}/export-adguard-metrics.sh"
[[ -x "$_agh_export" ]] || _agh_export="${REMOTE_DIR}/scripts/pi/export-adguard-metrics.sh"
if [[ -x "$_agh_export" ]]; then
  REMOTE_DIR="$REMOTE_DIR" bash "$_agh_export" \
    || echo "[export-state] WARN export-adguard-metrics failed" >&2
fi
_ssd_usb_py="${SCRIPT_DIR}/../lib/ssd-usb-metrics.py"
[[ -f "$_ssd_usb_py" ]] || _ssd_usb_py="${REMOTE_DIR}/scripts/lib/ssd-usb-metrics.py"
if [[ -f "$_ssd_usb_py" ]]; then
  python3 "$_ssd_usb_py" export 2>/dev/null || true
  if [[ -f /var/lib/pi-gateway/metrics/ssd_usb.prom ]]; then
    if [[ "$(id -u)" -eq 0 ]]; then
      cat /var/lib/pi-gateway/metrics/ssd_usb.prom >>"$METRICS_FILE"
    else
      run_as_needed bash -c "cat /var/lib/pi-gateway/metrics/ssd_usb.prom >>\"$METRICS_FILE\""
    fi
  fi
fi
echo "[export-state] OK ${METRICS_FILE}"

# P2 yavaşlama — kartta ms; eşikte alarm
# shellcheck source=../lib/notify.sh
source "$SCRIPT_DIR/../lib/notify.sh"
load_telegram_from_hermes 2>/dev/null || true
DNS_LATENCY_WARN_MS="${DNS_LATENCY_WARN_MS:-150}"
PANEL_LATENCY_WARN_MS="${PANEL_LATENCY_WARN_MS:-800}"
dns_ms="$(python3 -c 'import json,sys
try:
    d=json.loads(sys.argv[1] or "{}")
except Exception:
    d={}
print(int(d.get("dns_latency_ms", -1) or -1))' "$probe_json" 2>/dev/null || echo -1)"
panel_ms="$(python3 -c 'import json,sys
try:
    d=json.loads(sys.argv[1] or "{}")
except Exception:
    d={}
print(int(d.get("panel_latency_ms", -1) or -1))' "$probe_json" 2>/dev/null || echo -1)"
slow=0
detail=""
if [[ "$dns_ms" =~ ^[0-9]+$ ]] && (( dns_ms > DNS_LATENCY_WARN_MS )); then
  slow=1
  detail="DNS ${dns_ms}ms (eşik ${DNS_LATENCY_WARN_MS}ms)"
fi
if [[ "$panel_ms" =~ ^[0-9]+$ ]] && (( panel_ms > PANEL_LATENCY_WARN_MS )); then
  slow=1
  detail="${detail:+$detail; }Panel ${panel_ms}ms (eşik ${PANEL_LATENCY_WARN_MS}ms)"
fi
if [[ "$slow" -eq 1 ]]; then
  notify_latency_slow "$(hostname -s 2>/dev/null || echo pi-gateway)" "$detail" || true
else
  notify_latency_ok || true
fi
