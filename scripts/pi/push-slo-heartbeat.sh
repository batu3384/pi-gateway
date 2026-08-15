#!/usr/bin/env bash
# Push Uptime Kuma SLO heartbeats from state.json
set -euo pipefail
REMOTE_DIR="${REMOTE_DIR:-/home/${USER}/pi-gateway}"
TOKEN_FILE="${REMOTE_DIR}/data/uptime-kuma/slo-push-tokens.env"
STATE_JSON="${PI_GATEWAY_STATE_JSON:-/var/lib/pi-gateway/state.json}"
[[ -f "$TOKEN_FILE" && -f "$STATE_JSON" ]] || exit 0
# shellcheck source=../lib/env-file.sh
source "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/../lib/env-file.sh"
read_remote_dotenv || exit 0

export TOKEN_FILE STATE_JSON
export OFFSITE_BACKUP_MAX_AGE_DAYS="${OFFSITE_BACKUP_MAX_AGE_DAYS:-7}"
export BACKUP_DRILL_MAX_AGE_DAYS="${BACKUP_DRILL_MAX_AGE_DAYS:-30}"

# shellcheck disable=SC1090
source "$TOKEN_FILE"

python3 <<'PY'
import json, os, urllib.parse, urllib.request
from pathlib import Path

state = json.loads(Path(os.environ["STATE_JSON"]).read_text(encoding="utf-8"))
offsite_max = int(os.environ.get("OFFSITE_BACKUP_MAX_AGE_DAYS", "7") or 0)
drill_max = int(os.environ.get("BACKUP_DRILL_MAX_AGE_DAYS", "30") or 0)

def push(env_key: str, status: str, msg: str) -> None:
    url = os.environ.get(env_key, "").strip()
    if not url:
        return
    sep = "&" if "?" in url else "?"
    full = f"{url}{sep}status={status}&msg={urllib.parse.quote(msg)}"
    try:
        urllib.request.urlopen(full, timeout=10).read()
    except Exception:
        pass

if state.get("storage_degraded") == 1 or state.get("ssd_mount_healthy") != 1:
    push("UPTIME_KUMA_PUSH_STORAGE", "down", "storage degraded or ssd unhealthy")
else:
    push("UPTIME_KUMA_PUSH_STORAGE", "up", "storage ok")

age = int(state.get("offsite_backup_age_days", -1))
if offsite_max > 0 and (age < 0 or age > offsite_max):
    push("UPTIME_KUMA_PUSH_OFFSITE", "down", f"offsite age {age}d")
else:
    push("UPTIME_KUMA_PUSH_OFFSITE", "up", f"offsite age {age}d")

dage = int(state.get("backup_restore_drill_age_days", -1))
if drill_max > 0 and (dage < 0 or dage > drill_max):
    push("UPTIME_KUMA_PUSH_DRILL", "down", f"drill age {dage}d")
else:
    push("UPTIME_KUMA_PUSH_DRILL", "up", f"drill age {dage}d")
PY
