#!/usr/bin/env bash
# Push SLO heartbeats to Gatus external endpoints (health timer)
# Gatus v5.4+: POST /api/v1/endpoints/{group}_{name}/push?success=bool
#              Authorization: Bearer <token>
set -euo pipefail
STATE_JSON="${PI_GATEWAY_STATE_JSON:-/var/lib/pi-gateway/state.json}"
GATUS_URL="${GATUS_URL:-http://127.0.0.1:3001}"
[[ -f "$STATE_JSON" ]] || exit 0
# shellcheck source=../lib/env-file.sh
source "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/../lib/env-file.sh"
read_remote_dotenv || exit 0

export STATE_JSON
export OFFSITE_BACKUP_MAX_AGE_DAYS="${OFFSITE_BACKUP_MAX_AGE_DAYS:-7}"
export BACKUP_DRILL_MAX_AGE_DAYS="${BACKUP_DRILL_MAX_AGE_DAYS:-30}"
export GATUS_URL

python3 <<'PY'
import json, os, sys, urllib.parse, urllib.request
from pathlib import Path

state = json.loads(Path(os.environ["STATE_JSON"]).read_text(encoding="utf-8"))
offsite_max = int(os.environ.get("OFFSITE_BACKUP_MAX_AGE_DAYS", "7") or 0)
drill_max = int(os.environ.get("BACKUP_DRILL_MAX_AGE_DAYS", "30") or 0)
base = os.environ.get("GATUS_URL", "http://127.0.0.1:3001").rstrip("/")
failures = []

NAME_MAP = {
    "GATUS_PUSH_TOKEN_STORAGE": "slo_slo-storage",
    "GATUS_PUSH_TOKEN_OFFSITE": "slo_slo-offsite-backup",
    "GATUS_PUSH_TOKEN_DRILL": "slo_slo-restore-drill",
}

def push(env_key: str, ok: bool, msg: str) -> None:
    token = os.environ.get(env_key, "").strip()
    key = NAME_MAP.get(env_key)
    if not token or not key:
        return
    url = f"{base}/api/v1/endpoints/{key}/external"
    url += "?" + urllib.parse.urlencode({"success": "true" if ok else "false", "message": msg})
    req = urllib.request.Request(url, method="POST", headers={"Authorization": f"Bearer {token}"})
    try:
        urllib.request.urlopen(req, timeout=10).read()
    except Exception as exc:
        print(f"[slo-heartbeat] FAIL {env_key}: {type(exc).__name__}", file=sys.stderr)
        failures.append(env_key)

if state.get("storage_degraded") == 1 or state.get("ssd_mount_healthy") != 1:
    push("GATUS_PUSH_TOKEN_STORAGE", False, "storage degraded or ssd unhealthy")
else:
    push("GATUS_PUSH_TOKEN_STORAGE", True, "storage ok")

age = int(state.get("offsite_backup_age_days", -1))
if offsite_max > 0 and (age < 0 or age > offsite_max):
    push("GATUS_PUSH_TOKEN_OFFSITE", False, f"offsite age {age}d")
else:
    push("GATUS_PUSH_TOKEN_OFFSITE", True, f"offsite age {age}d")

dage = int(state.get("backup_restore_drill_age_days", -1))
if drill_max > 0 and (dage < 0 or dage > drill_max):
    push("GATUS_PUSH_TOKEN_DRILL", False, f"drill age {dage}d")
else:
    push("GATUS_PUSH_TOKEN_DRILL", True, f"drill age {dage}d")

if failures:
    raise SystemExit(f"heartbeat push failed: {', '.join(sorted(set(failures)))}")
PY
