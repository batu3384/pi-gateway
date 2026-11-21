#!/usr/bin/env bash
# Jarvis sabah/trend brifingi: anlık snapshot + VictoriaMetrics 7g trend + OpenBot 24s filo durumu.
# Salt okunur, sıfır gizli değer, sıfır yan etki.
set -euo pipefail
export PATH="/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin:${PATH:-}"

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REMOTE_DIR="${REMOTE_DIR:-/home/${USER:-pi}/pi-gateway}"

if [[ "${1:-}" == "--self-check" ]]; then
  python3 - <<'PY'
import json

sample = {"status": "success", "data": {"result": [{"value": [1700000000, "42.567"]}]}}
val = float(sample["data"]["result"][0]["value"][1])
assert abs(val - 42.567) < 1e-6, "scalar parse fail"
print("[jarvis-health-brief] self-check OK")
PY
  exit 0
fi

if [[ -f "${SCRIPT_DIR}/../lib/env-file.sh" ]]; then
  # shellcheck source=../lib/env-file.sh
  source "${SCRIPT_DIR}/../lib/env-file.sh"
  read_remote_dotenv || true
fi
if [[ -f "${SCRIPT_DIR}/../lib/openbot-paths.sh" ]]; then
  # shellcheck source=../lib/openbot-paths.sh
  source "${SCRIPT_DIR}/../lib/openbot-paths.sh"
fi

export REMOTE_DIR
if [[ -x "${SCRIPT_DIR}/jarvis-snapshot.sh" ]]; then
  bash "${SCRIPT_DIR}/jarvis-snapshot.sh"
elif [[ -x "${REMOTE_DIR}/scripts/pi/jarvis-snapshot.sh" ]]; then
  bash "${REMOTE_DIR}/scripts/pi/jarvis-snapshot.sh"
fi

echo ""
echo "=== VictoriaMetrics 7-Day Trends ==="
python3 - <<'PY'
import json
import subprocess
import urllib.parse


def vm_scalar(promql: str):
    qs = urllib.parse.urlencode({"query": promql})
    url = f"http://127.0.0.1:8428/api/v1/query?{qs}"
    try:
        raw = subprocess.check_output(
            ["docker", "exec", "victoriametrics", "wget", "-qO-", "-T", "4", url],
            text=True,
            timeout=8,
            stderr=subprocess.DEVNULL,
        )
        data = json.loads(raw)
        if data.get("status") != "success":
            return None
        res = data.get("data", {}).get("result") or []
        if not res:
            return None
        return float(res[0]["value"][1])
    except (subprocess.SubprocessError, OSError, ValueError, KeyError, IndexError):
        return None


def fmt(val, spec=".1f", suffix=""):
    if val is None:
        return "n/a"
    return f"{val:{spec}}{suffix}"


ram_min = vm_scalar("min_over_time(node_memory_MemAvailable_bytes[7d])/1048576")
ram_avg = vm_scalar("avg_over_time(node_memory_MemAvailable_bytes[7d])/1048576")
temp_max = vm_scalar("max(max_over_time(node_hwmon_temp_celsius[7d]))")
sd_now = vm_scalar("pi_gateway_root_usage_percent")
sd_delta = vm_scalar("delta(pi_gateway_root_usage_percent[7d])")
ssd_now = vm_scalar("pi_gateway_ssd_usage_percent")
ssd_delta = vm_scalar("delta(pi_gateway_ssd_usage_percent[7d])")
dns_ms = vm_scalar("avg_over_time(pi_gateway_dns_latency_ms[7d])")
agh_blk = vm_scalar("avg_over_time(pi_gateway_adguard_blocked_ratio[7d])*100")
usb_rst = vm_scalar("max_over_time(pi_gateway_ssd_usb_reset_events_24h[7d])")
usb_io = vm_scalar("max_over_time(pi_gateway_ssd_usb_io_errors_24h[7d])")
usb_crc = vm_scalar("max_over_time(pi_gateway_ssd_usb_crc_errors[7d])")
isp_dl = vm_scalar("avg_over_time(pi_gateway_isp_download_mbps[7d])")

print(f"RAM avail:  7d_min={fmt(ram_min, '.0f', 'MiB')} | 7d_avg={fmt(ram_avg, '.0f', 'MiB')}")
print(f"Thermal:    7d_max={fmt(temp_max, '.1f', 'C')}")
print(
    f"Disks 7d:   SD={fmt(sd_now, '.0f', '%')} (Δ{fmt(sd_delta, '+.1f', 'pp')}) | "
    f"SSD={fmt(ssd_now, '.0f', '%')} (Δ{fmt(ssd_delta, '+.1f', 'pp')})"
)
print(f"DNS & ISP:  dns_7d_avg={fmt(dns_ms, '.1f', 'ms')} | agh_block_7d={fmt(agh_blk, '.1f', '%')} | isp_7d_avg={fmt(isp_dl, '.0f', 'Mbps')}")
print(f"SSD USB 7d: resets_peak={fmt(usb_rst, '.0f')} | io_err_peak={fmt(usb_io, '.0f')} | crc_max={fmt(usb_crc, '.0f')}")
PY

echo ""
echo "=== OpenBot Fleet (24h) ==="
OB_STATE=""
OB_DB=""
if command -v openbot_state_dir >/dev/null 2>&1; then
  OB_STATE="$(openbot_state_dir)"
  OB_DB="$(openbot_db_path)"
fi
OB_VER="$(openbot status 2>/dev/null | awk 'NR==1{v=$0} END{print v}' || true)"
if [[ -z "$OB_VER" ]]; then
  OB_VER="$(sudo -n openbot status 2>/dev/null | awk 'NR==1{v=$0} END{print v}' || true)"
fi
OB_VER="${OB_VER:-unknown}"
OB_VER="$OB_VER" OB_STATE="$OB_STATE" OB_DB="$OB_DB" python3 - <<'PY'
import json
import os
import sqlite3

ver = os.environ.get("OB_VER") or "unknown"
state = os.environ.get("OB_STATE") or ""
db = os.environ.get("OB_DB") or ""

push_n = "?"
push_path = os.path.join(state, "openbot-push-notifications-v1.json") if state else ""
if push_path and os.path.isfile(push_path):
    try:
        push_n = str(len(json.load(open(push_path, encoding="utf-8")).get("registrations") or []))
    except (OSError, ValueError):
        push_n = "err"

if not db or not os.path.isfile(db):
    print(f"Version:    {ver} | db=missing | push_regs={push_n}")
    raise SystemExit(0)

try:
    con = sqlite3.connect(f"file:{db}?mode=ro", uri=True)
    agents = con.execute("select count(*) from projection_agents").fetchone()[0]
    routines = con.execute("select count(*) from projection_agent_routines where active=1").fetchone()[0]
    ok_24h = con.execute(
        "select count(*) from projection_routine_runs where status='succeeded' and datetime(created_at) >= datetime('now', '-24 hours')"
    ).fetchone()[0]
    fail_24h = con.execute(
        "select count(*) from projection_routine_runs where status='failed' and datetime(created_at) >= datetime('now', '-24 hours')"
    ).fetchone()[0]
    failed_names = [
        r[0]
        for r in con.execute(
            """select distinct ar.name from projection_routine_runs rr
               join projection_agent_routines ar on ar.routine_id = rr.routine_id
               where rr.status='failed' and datetime(rr.created_at) >= datetime('now', '-24 hours')
               limit 5"""
        )
    ]
    con.close()
    fail_note = f" ({', '.join(failed_names)})" if failed_names else ""
    print(f"Version:    {ver} | agents={agents} | active_routines={routines} | push_regs={push_n}")
    print(f"Runs 24h:   succeeded={ok_24h} | failed={fail_24h}{fail_note}")
except sqlite3.Error as exc:
    print(f"Version:    {ver} | db_err={exc} | push_regs={push_n}")
PY
