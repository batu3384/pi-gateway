#!/usr/bin/env bash
# YouTube/Instagram takılmasını DNS, Pi ve modem kanıtlarından ayır.
# Salt okunur; modem veya AdGuard ayarı değiştirmez.
set -euo pipefail
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REMOTE_DIR="${REMOTE_DIR:-/home/${USER}/pi-gateway}"
VIDEO_IP="${VIDEO_TEST_IP:-}"
if [[ -z "$VIDEO_IP" ]]; then
  echo "Kullanim: VIDEO_TEST_IP=192.168.1.x $0" >&2
  exit 2
fi
# shellcheck source=../lib/env-file.sh
source "$SCRIPT_DIR/../lib/env-file.sh"
read_remote_dotenv || {
  echo "[video-diagnose] HATA: .env dotenv parser hatasi" >&2
  exit 1
}
# shellcheck source=../lib/adguard-api.sh
source "$SCRIPT_DIR/../lib/adguard-api.sh"

PI_IP="${PI_STATIC_IP:-}"
ADGUARD_WEB_PORT="${ADGUARD_WEB_PORT:-8080}"
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
export BASE COOKIE REMOTE_DIR VIDEO_IP PI_IP

echo "=== Video yol kanit toplama ==="
echo "Cihaz=${VIDEO_IP} — salt okunur"
echo "Zaman=$(date -Is)"
echo "--- Pi kaynak kontrolu ---"
awk '/^MemAvailable:/ {printf "MemAvailable=%dMiB\n", int($2/1024)} /^MemTotal:/ {printf "MemTotal=%dMiB\n", int($2/1024)}' /proc/meminfo
awk '{print "Load1=" $1 " Load5=" $2 " Load15=" $3}' /proc/loadavg
if command -v ping >/dev/null 2>&1; then
  gateway="${LAN_GATEWAY:-192.168.1.1}"
  echo "LAN cihaz RTT/packet loss:"
  ping -c 20 -W 1 "$VIDEO_IP" 2>&1 | awk '/packet loss|round-trip|rtt/ {print}' || true
  echo "Gateway RTT/packet loss:"
  ping -c 10 -W 1 "$gateway" 2>&1 | awk '/packet loss|round-trip|rtt/ {print}' || true
  echo "Internet RTT/packet loss:"
  ping -c 10 -W 1 1.1.1.1 2>&1 | awk '/packet loss|round-trip|rtt/ {print}' || true
fi

python3 - <<'PY'
import json, os, subprocess, sys
from collections import Counter
from urllib.parse import quote

base = os.environ["BASE"]
cookie = os.environ["COOKIE"]
video_ip = os.environ["VIDEO_IP"]
remote_dir = os.environ["REMOTE_DIR"]
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
for row in querylog.get("data", []):
    client = str(row.get("client_ip") or row.get("client") or "")
    if client != video_ip:
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
print(f"AdGuard video-domain sorgusu: {len(matched)}")
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
device = modem_device(inventory, ip=video_ip)
if not device:
    device = next(
        (
            item
            for item in inventory.get("devices", [])
            if str(item.get("ip") or "") == video_ip
        ),
        {},
    )
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
PY
