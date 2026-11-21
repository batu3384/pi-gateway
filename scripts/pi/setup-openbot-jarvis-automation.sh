#!/usr/bin/env bash
# Uyarı köprüsü + Jarvis rutinleri (native OpenBot).
set -euo pipefail
REMOTE_DIR="${REMOTE_DIR:-/home/${USER}/pi-gateway}"
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=../lib/env-file.sh
source "${SCRIPT_DIR}/../lib/env-file.sh"
# shellcheck source=../lib/openbot-paths.sh
source "${SCRIPT_DIR}/../lib/openbot-paths.sh"
read_remote_dotenv || true

OPENBOT_STATE_DIR="$(openbot_state_dir)"
OPENBOT_DATA_ROOT="$(openbot_data_root)"
export OPENBOT_STATE_DIR OPENBOT_DATA_ROOT

log() { echo "[jarvis-automation-setup] $*"; }

chmod +x "$SCRIPT_DIR/jarvis-send.sh" \
  "$SCRIPT_DIR/setup-openbot-jarvis-routines.sh" \
  "$SCRIPT_DIR/gateway-status.sh" \
  "${SCRIPT_DIR}/../lib/openbot-paths.sh"

envf="${REMOTE_DIR}/.env"
touch "$envf"
for kv in \
  "OPENBOT_JARVIS_AUTOMATION=true" \
  "NOTIFY_BACKEND=openbot" \
  "OPENBOT_JARVIS=true" \
  "OPENBOT_NATIVE=true" \
  "OPENBOT_DATA_ROOT=${OPENBOT_DATA_ROOT}" \
  "OPENBOT_STATE_DIR=${OPENBOT_STATE_DIR}"; do
  key="${kv%%=*}"
  if grep -q "^${key}=" "$envf" 2>/dev/null; then
    sed -i "s|^${key}=.*|${kv}|" "$envf"
  else
    echo "$kv" >>"$envf"
  fi
done

bash "$SCRIPT_DIR/setup-openbot-jarvis-routines.sh"

if ! grep -q '^JARVIS_AGENT_ID=' "$envf"; then
  aid="$(OPENBOT_STATE_DIR="$OPENBOT_STATE_DIR" python3 - <<PY
import json, os, sqlite3, sys
db = os.path.join(os.environ["OPENBOT_STATE_DIR"], "openbot.db")
con = sqlite3.connect(f"file:{db}?mode=ro", uri=True)
rows = [json.loads(b) for (b,) in con.execute("select agent_json from projection_agents")]
match = [a for a in rows if a.get("name") == "Jarvis"]
pick = match[0] if len(match) == 1 else (rows[0] if len(rows) == 1 else None)
if not pick:
    sys.exit(1)
print(pick["id"])
PY
)"
  echo "JARVIS_AGENT_ID=${aid}" >>"$envf"
  log "JARVIS_AGENT_ID yazıldı"
fi

sudo REMOTE_DIR="$REMOTE_DIR" bash "$REMOTE_DIR/scripts/pi/install-privileged-scripts.sh"
log "Uyarılar: notify.sh → jarvis-send. Bültenler: Jarvis rutinleri."