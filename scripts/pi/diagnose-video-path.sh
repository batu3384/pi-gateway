#!/usr/bin/env bash
# YouTube/Instagram takılmasını DNS, Pi ve modem kanıtlarından ayır.
# Salt okunur; modem veya AdGuard ayarı değiştirmez.
set -euo pipefail
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REMOTE_DIR="${REMOTE_DIR:-/home/${USER}/pi-gateway}"
# shellcheck source=../lib/env-file.sh
source "$SCRIPT_DIR/../lib/env-file.sh"
read_remote_dotenv || {
  echo "[video-diagnose] HATA: .env dotenv parser hatasi" >&2
  exit 1
}
VIDEO_IP="${VIDEO_TEST_IP:-}"
VIDEO_CLIENT_MAX_LOSS_PERCENT="${VIDEO_CLIENT_MAX_LOSS_PERCENT:-20}"
VIDEO_CLIENT_MAX_JITTER_MS="${VIDEO_CLIENT_MAX_JITTER_MS:-30}"
VIDEO_HTTP_PROBE_URL="${VIDEO_HTTP_PROBE_URL:-https://www.youtube.com/generate_204}"
VIDEO_HTTP_PROBE_TIMEOUT_SEC="${VIDEO_HTTP_PROBE_TIMEOUT_SEC:-8}"
if ! python3 - "$VIDEO_IP" "$VIDEO_CLIENT_MAX_LOSS_PERCENT" \
  "$VIDEO_CLIENT_MAX_JITTER_MS" \
  "$VIDEO_HTTP_PROBE_URL" "$VIDEO_HTTP_PROBE_TIMEOUT_SEC" <<'PY'
import ipaddress
import sys
from urllib.parse import urlparse

try:
    ipaddress.ip_address(sys.argv[1])
    loss = int(sys.argv[2])
    jitter = int(sys.argv[3])
    timeout = int(sys.argv[5])
    parsed = urlparse(sys.argv[4])
    if not 0 <= loss <= 100 or not 0 <= jitter <= 1000 or not 1 <= timeout <= 60:
        raise ValueError
    if parsed.scheme != "https" or not parsed.hostname or parsed.username or parsed.password:
        raise ValueError
except (IndexError, TypeError, ValueError):
    raise SystemExit(1)
PY
then
  echo "Kullanim: VIDEO_TEST_IP=192.168.1.x $0" >&2
  echo "[video-diagnose] HATA: hedef IP veya probe ayari gecersiz" >&2
  exit 2
fi
# shellcheck source=../lib/adguard-api.sh
source "$SCRIPT_DIR/../lib/adguard-api.sh"

PI_IP="${PI_STATIC_IP:-}"
ADGUARD_WEB_PORT="${ADGUARD_WEB_PORT:-8080}"
VIDEO_QUERY_RECENCY_SEC="${VIDEO_QUERY_RECENCY_SEC:-300}"
AGH_ADMIN_USER="${AGH_ADMIN_USER:-admin}"
AGH_ADMIN_PASSWORD="${AGH_ADMIN_PASSWORD:-}"
BASE="http://127.0.0.1:${ADGUARD_WEB_PORT}"
COOKIE="$(mktemp)"
trap 'rm -f "$COOKIE"' EXIT
[[ -n "$AGH_ADMIN_PASSWORD" ]] || {
  echo "[video-diagnose] HATA: AGH_ADMIN_PASSWORD bos" >&2
  exit 1
}
agh_login "$BASE" "$COOKIE" "$AGH_ADMIN_USER" "$AGH_ADMIN_PASSWORD" || {
  echo "[video-diagnose] HATA: AdGuard login basarisiz" >&2
  exit 1
}
export BASE COOKIE REMOTE_DIR VIDEO_IP PI_IP VIDEO_QUERY_RECENCY_SEC

echo "=== Video yol kanit toplama ==="
echo "Cihaz=${VIDEO_IP} — salt okunur"
echo "Zaman=$(date -Is)"
echo "--- Pi kaynak kontrolu ---"
awk '/^MemAvailable:/ {printf "MemAvailable=%dMiB\n", int($2/1024)} /^MemTotal:/ {printf "MemTotal=%dMiB\n", int($2/1024)}' /proc/meminfo
awk '{print "Load1=" $1 " Load5=" $2 " Load15=" $3}' /proc/loadavg
video_probe_fail=0
video_probe_warn=0
VIDEO_CLIENT_PACKET_LOSS=-1
VIDEO_CLIENT_JITTER_MS=-1
VIDEO_GATEWAY_PACKET_LOSS=-1
VIDEO_WAN_PACKET_LOSS=-1
probe_ping() {
  local label="$1" target="$2" count="$3" output parsed ping_rc=0
  output="$(ping -c "$count" -W 1 "$target" 2>&1)" || ping_rc=$?
  printf '%s\n' "$output" | awk '/packet loss|round-trip|rtt/ {print}'
  parsed="$(printf '%s\n' "$output" | python3 -c '
import re
import sys

text = sys.stdin.read()
loss_match = re.search(r"(\d+(?:\.\d+)?)%\s+packet loss", text)
rtt_match = re.search(r"=\s*([0-9.]+)/([0-9.]+)/([0-9.]+)/([0-9.]+)", text)
if not loss_match:
    print("unknown unknown unknown unknown")
else:
    loss = int(round(float(loss_match.group(1))))
    avg = rtt_match.group(2) if rtt_match else "unknown"
    maximum = rtt_match.group(3) if rtt_match else "unknown"
    jitter = rtt_match.group(4) if rtt_match else "unknown"
    print(f"{loss} {avg} {maximum} {jitter}")
')"
  local loss avg maximum jitter
  read -r loss avg maximum jitter <<<"$parsed"
  if [[ "$loss" == "unknown" ]]; then
    echo "VIDEO_PING label=$label status=unknown rc=$ping_rc"
    if [[ "$label" == "client" ]]; then
      video_probe_warn=1
    else
      video_probe_fail=1
    fi
    return 0
  fi
  case "$label" in
    client) VIDEO_CLIENT_PACKET_LOSS="$loss" ;;
    gateway) VIDEO_GATEWAY_PACKET_LOSS="$loss" ;;
    wan) VIDEO_WAN_PACKET_LOSS="$loss" ;;
  esac
  local probe_status=ok
  if [[ "$label" == "client" ]]; then
    if (( loss > VIDEO_CLIENT_MAX_LOSS_PERCENT )); then
      video_probe_warn=1
      probe_status=warn
    fi
    if [[ "$jitter" != "unknown" ]]; then
      VIDEO_CLIENT_JITTER_MS="$jitter"
      if awk -v value="$jitter" -v threshold="$VIDEO_CLIENT_MAX_JITTER_MS" \
        'BEGIN { exit !(value > threshold) }'; then
        video_probe_warn=1
        probe_status=warn
      fi
    fi
  elif (( loss > 0 )); then
    video_probe_fail=1
    probe_status=fail
  fi
  echo "VIDEO_PING label=$label status=$probe_status packet_loss=${loss}% avg_ms=$avg max_ms=$maximum jitter_ms=$jitter"
}
if command -v ping >/dev/null 2>&1; then
  gateway="${LAN_GATEWAY:-192.168.1.1}"
  echo "LAN cihaz RTT/packet loss:"
  probe_ping client "$VIDEO_IP" 20
  echo "Gateway RTT/packet loss:"
  probe_ping gateway "$gateway" 10
  echo "Internet RTT/packet loss:"
  probe_ping wan 1.1.1.1 10
else
  echo "VIDEO_PING status=unknown reason=ping-unavailable"
  video_probe_fail=1
fi

http_probe_rc=0
http_probe="$(curl -4LfsS --max-time "$VIDEO_HTTP_PROBE_TIMEOUT_SEC" \
  -o /dev/null -w '%{http_code} %{time_total}' "$VIDEO_HTTP_PROBE_URL" 2>/dev/null)" \
  || http_probe_rc=$?
if [[ "$http_probe_rc" -eq 0 ]]; then
  read -r http_code http_time <<<"$http_probe"
  if [[ "$http_code" =~ ^2[0-9][0-9]$|^3[0-9][0-9]$ ]]; then
    echo "VIDEO_HTTP_PROBE=ok code=$http_code time_s=$http_time source=pi"
  else
    echo "VIDEO_HTTP_PROBE=fail code=${http_code:-unknown} source=pi"
    video_probe_fail=1
  fi
else
  echo "VIDEO_HTTP_PROBE=fail rc=$http_probe_rc source=pi"
  video_probe_fail=1
fi

set +e
python3 - <<'PY'
import json, os, subprocess, sys, time
from collections import Counter
from datetime import datetime, timezone
from urllib.parse import quote

base = os.environ["BASE"]
cookie = os.environ["COOKIE"]
video_ip = os.environ["VIDEO_IP"]
remote_dir = os.environ["REMOTE_DIR"]
recency_sec = int(os.environ.get("VIDEO_QUERY_RECENCY_SEC", "300"))
now = time.time()
sys.path.insert(0, os.path.join(remote_dir, "scripts", "lib"))
from modem_inventory import load_modem_inventory, modem_device

def api(path):
    return json.loads(
        subprocess.check_output(
            ["curl", "-fsS", "-b", cookie, f"{base}{path}"],
            text=True,
        )
    )

querylog = api("/control/querylog?older_than=&limit=5000")
domains = Counter()
matched = []
stale_rows = 0
unknown_time_rows = 0

def row_epoch(row):
    for key in ("time", "client_ts", "timestamp"):
        value = row.get(key)
        if value in (None, ""):
            continue
        try:
            number = float(value)
            return number / 1000 if number > 100000000000 else number
        except (TypeError, ValueError):
            try:
                parsed = datetime.fromisoformat(str(value).replace("Z", "+00:00"))
                if parsed.tzinfo is None:
                    parsed = parsed.replace(tzinfo=timezone.utc)
                return parsed.timestamp()
            except ValueError:
                continue
    return None

for row in querylog.get("data", []):
    client = str(row.get("client_ip") or row.get("client") or "")
    if client != video_ip:
        continue
    event_ts = row_epoch(row)
    if event_ts is None:
        unknown_time_rows += 1
        continue
    if event_ts < now - recency_sec or event_ts > now + 60:
        stale_rows += 1
        continue
    question = row.get("question")
    if isinstance(question, dict):
        host = str(question.get("name") or "")
    else:
        host = str(row.get("domain") or row.get("host") or question or "")
    host = host.rstrip(".").lower()
    if any(
        marker in host
        for marker in (
            "googlevideo.com",
            "ytimg.com",
            "youtube.com",
            "instagram",
            "cdninstagram.com",
            "fbcdn.net",
        )
    ):
        domains[host] += 1
        matched.append(
            {
                "host": host,
                "reason": row.get("reason", ""),
                "elapsed": row.get("elapsed") or row.get("processing_time") or "",
            }
        )
print(f"AdGuard video-domain sorgusu (son {recency_sec}s): {len(matched)}")
print(f"  recent olmayan satir: {stale_rows}, timestamp bilinmeyen: {unknown_time_rows}")
if not matched:
    print("  UNKNOWN: son pencerede cihaz için video DNS kanıtı yok")
for host, count in domains.most_common(20):
    rows = [row for row in matched if row["host"] == host]
    blocked = sum(
        1
        for row in rows
        if "filtered" in str(row["reason"]).lower()
        and "notfiltered" not in str(row["reason"]).lower()
    )
    print(f"  {host}: {count} sorgu, {blocked} block")

print("AdGuard check_host:")
for host in (
    "googlevideo.com",
    "ytimg.com",
    "cdninstagram.com",
    "instagram.fna.fbcdn.net",
):
    result = api(f"/control/filtering/check_host?name={quote(host, safe='')}")
    print(f"  {host}: {result.get('reason', '?')}")

inventory = load_modem_inventory()
device = modem_device(inventory, ip=video_ip) if inventory.get("fresh") else {}
if device:
    print(
        "Modem snapshot: "
        f"state={'fresh' if inventory.get('fresh') else 'stale/missing'} "
        f"age={inventory.get('age') or '?'}s "
        f"name={device.get('name') or '?'} "
        f"network={device.get('network') or '?'} "
        f"band={device.get('band') or '?'} "
        f"channel={device.get('channel') or '?'} "
        f"rssi={device.get('rssi') or '?'} "
        f"confidence={device.get('confidence') or '?'} "
        f"privacy_mac={device.get('privacy_mac', '?')} "
        f"source={device.get('source') or '?'} "
        f"last_seen={device.get('last_seen') or '?'}"
    )
else:
    print(
        "Modem snapshot: cihaz yok veya snapshot yok "
        f"(state={'fresh' if inventory.get('fresh') else 'stale/missing'})"
    )
print("Not: AdGuard query log transportu kanıtlamaz; DoH/DoT/DoQ ayrı ağ ölçümü ister.")
if not matched:
    print("VIDEO_QUERY_STATUS=WARN")
    sys.exit(10)
print("VIDEO_QUERY_STATUS=OK")
PY
query_rc=$?
set -e
if [[ "$query_rc" -ne 0 ]]; then
  video_probe_warn=1
fi

VIDEO_PROBE_STATUS=OK
if (( video_probe_fail )); then
  VIDEO_PROBE_STATUS=FAIL
elif (( video_probe_warn )); then
  VIDEO_PROBE_STATUS=WARN
fi
echo "VIDEO_CLIENT_PACKET_LOSS=${VIDEO_CLIENT_PACKET_LOSS}%"
echo "VIDEO_CLIENT_JITTER_MS=$VIDEO_CLIENT_JITTER_MS"
echo "VIDEO_GATEWAY_PACKET_LOSS=${VIDEO_GATEWAY_PACKET_LOSS}%"
echo "VIDEO_WAN_PACKET_LOSS=${VIDEO_WAN_PACKET_LOSS}%"
echo "VIDEO_PROBE_STATUS=$VIDEO_PROBE_STATUS"
case "$VIDEO_PROBE_STATUS" in
  FAIL) exit 1 ;;
  WARN) exit 10 ;;
  *) exit 0 ;;
esac
