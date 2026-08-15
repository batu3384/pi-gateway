#!/usr/bin/env bash
# Uptime Kuma PUSH monitors for SLO signals (storage, offsite, drill)
set -euo pipefail
REMOTE_DIR="${REMOTE_DIR:-/home/${USER}/pi-gateway}"
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=../lib/env-file.sh
source "$SCRIPT_DIR/../lib/env-file.sh"
read_remote_dotenv || { echo "[slo-monitors] HATA: .env dotenv parser hatasi" >&2; exit 1; }

KUMA_URL="${UPTIME_KUMA_URL:-http://127.0.0.1:3001}"
KUMA_USER="${UPTIME_KUMA_ADMIN_USER:-admin}"
KUMA_PASS="${UPTIME_KUMA_ADMIN_PASSWORD:-}"
TOKEN_FILE="${REMOTE_DIR}/data/uptime-kuma/slo-push-tokens.env"

log() { echo "[slo-monitors] $*"; }
[[ -n "$KUMA_PASS" ]] || { log "HATA: UPTIME_KUMA_ADMIN_PASSWORD bos"; exit 1; }
docker ps --format '{{.Names}}' | grep -q '^uptime-kuma$' || { log "uptime-kuma yok — atlaniyor"; exit 0; }

mkdir -p "$(dirname "$TOKEN_FILE")"
export KUMA_URL KUMA_USER KUMA_PASS TOKEN_FILE
docker run --rm --network host \
  -e KUMA_URL -e KUMA_USER -e KUMA_PASS -e TOKEN_FILE \
  -v "${REMOTE_DIR}/data/uptime-kuma:/tokens:rw" \
  python:3.12-alpine sh -c '
    pip install -q uptime-kuma-api2
    python - <<'"'"'PY'"'"'
import os
from pathlib import Path
from uptime_kuma_api import UptimeKumaApi, MonitorType

url = os.environ["KUMA_URL"].rstrip("/")
user = os.environ["KUMA_USER"]
password = os.environ["KUMA_PASS"]
token_file = Path(os.environ["TOKEN_FILE"])
monitors = [
    ("SLO Storage Healthy", "UPTIME_KUMA_PUSH_STORAGE"),
    ("SLO Offsite Backup", "UPTIME_KUMA_PUSH_OFFSITE"),
    ("SLO Restore Drill", "UPTIME_KUMA_PUSH_DRILL"),
]
api = UptimeKumaApi(url, timeout=60)
api.login(user, password)
by_name = {m.get("name"): m for m in api.get_monitors()}
lines = []
for name, env_key in monitors:
    m = by_name.get(name)
    if not m or m.get("type") != "push":
        api.add_monitor(name=name, type=MonitorType.PUSH, interval=300, maxretries=1)
        by_name = {x.get("name"): x for x in api.get_monitors()}
        m = by_name[name]
        print(f"added push: {name}")
    token = m.get("pushToken") or ""
    if not token:
        raise SystemExit(f"pushToken yok: {name}")
    lines.append(f"{env_key}={url}/api/push/{token}")
token_file.parent.mkdir(parents=True, exist_ok=True)
token_file.write_text("\n".join(lines) + "\n", encoding="utf-8")
token_file.chmod(0o600)
print(f"tokens: {token_file}")
api.disconnect()
PY
  '
log "Tamamlandi — $TOKEN_FILE"
