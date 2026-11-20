#!/usr/bin/env bash
# Jarvis workspace + skill senkronu (native OpenBot, host kabuğu).
set -euo pipefail
REMOTE_DIR="${REMOTE_DIR:-/home/${USER}/pi-gateway}"
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=../lib/env-file.sh
source "${SCRIPT_DIR}/../lib/env-file.sh"
# shellcheck source=../lib/openbot-paths.sh
source "${SCRIPT_DIR}/../lib/openbot-paths.sh"
read_remote_dotenv || { echo "HATA: .env" >&2; exit 1; }

DATA_ROOT="$(openbot_data_root)"
STATE_DIR="$(openbot_state_dir)"
DB="${STATE_DIR}/openbot.db"

log() { echo "[openbot-jarvis-migration] $*"; }

[[ "${HERMES_TELEGRAM_GATEWAY:-false}" == "true" ]] && {
  log "HATA: önce HERMES_TELEGRAM_GATEWAY=false"
  exit 1
}

if systemctl is-active --quiet hermes-gateway 2>/dev/null; then
  log "HATA: hermes-gateway hâlâ active"
  exit 1
fi

HERMES_CRON="${HERMES_HOME:-$HOME/.hermes}/cron/jobs.json"
if [[ -f "$HERMES_CRON" ]]; then
  python3 - <<PY
import json
from pathlib import Path
p = Path("${HERMES_CRON}")
data = json.loads(p.read_text())
jobs = data.get("jobs", data if isinstance(data, list) else [])
for j in jobs:
    if isinstance(j, dict):
        j["enabled"] = False
data["jobs"] = jobs
p.write_text(json.dumps(data, ensure_ascii=False, indent=2) + "\n")
PY
fi

[[ -f "$DB" ]] || { log "HATA: openbot.db yok: $DB"; exit 1; }

export OPENBOT_DATA_ROOT="$DATA_ROOT" STATE_DIR="$STATE_DIR"
AGENT_JSON="$(REMOTE_DIR="$REMOTE_DIR" python3 - <<'PY'
import json, os, sqlite3
from pathlib import Path

db = Path(os.environ["STATE_DIR"]) / "openbot.db"
root = Path(os.environ["OPENBOT_DATA_ROOT"])
con = sqlite3.connect(db)
rows = [json.loads(b) for (b,) in con.execute("select agent_json from projection_agents")]
match = [a for a in rows if a.get("name") == "Jarvis"]
agent = match[0] if len(match) == 1 else (rows[0] if len(rows) == 1 else None)
if not agent:
    raise SystemExit(1)
ws = agent.get("workspacePath", "")
if ws.startswith("/data/"):
    ws = str(root / ws.removeprefix("/data/"))
elif ws.startswith("/data/OpenBot/"):
    ws = str(root / "OpenBot" / ws.removeprefix("/data/OpenBot/"))
print(ws)
PY
)" || AGENT_JSON=""

if [[ -n "$AGENT_JSON" && -d "$AGENT_JSON" ]]; then
  if [[ ! -s "${AGENT_JSON}/AGENTS.md" ]]; then
    cp "${REMOTE_DIR}/config/openbot/fleet/jarvis.md" "${AGENT_JSON}/SOUL.md"
    cp "${REMOTE_DIR}/config/openbot/fleet/jarvis.md" "${AGENT_JSON}/AGENTS.md"
  fi
  for s in pi-gateway-ops menu dns ssd backup recover; do
    for root in .agents .claude; do
      mkdir -p "${AGENT_JSON}/${root}/skills"
      rm -rf "${AGENT_JSON}/${root}/skills/${s}"
      cp -a "${REMOTE_DIR}/config/openbot/fleet/skills/${s}" "${AGENT_JSON}/${root}/skills/"
      sed -i "s|__REMOTE_DIR__|${REMOTE_DIR}|g" "${AGENT_JSON}/${root}/skills/${s}/SKILL.md" 2>/dev/null || true
    done
  done
  log "Jarvis workspace: $AGENT_JSON"
fi

if [[ -x "${SCRIPT_DIR}/setup-openbot-zai-jarvis.sh" ]]; then
  REMOTE_DIR="$REMOTE_DIR" bash "${SCRIPT_DIR}/setup-openbot-zai-jarvis.sh"
fi

log "Tamam — native host; repo: $REMOTE_DIR"