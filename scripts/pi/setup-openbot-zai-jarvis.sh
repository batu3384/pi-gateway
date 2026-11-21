#!/usr/bin/env bash
# z.ai Coding Plan (opencode) + Jarvis model glm-5.3 — native OpenBot.
set -euo pipefail
REMOTE_DIR="${REMOTE_DIR:-/home/${USER}/pi-gateway}"
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=../lib/env-file.sh
source "${SCRIPT_DIR}/../lib/env-file.sh"
# shellcheck source=../lib/openbot-paths.sh
source "${SCRIPT_DIR}/../lib/openbot-paths.sh"
read_remote_dotenv || { echo "HATA: .env" >&2; exit 1; }

STATE_DIR="$(openbot_state_dir)"
DB="${STATE_DIR}/openbot.db"
ZAI_ENV="${OPENBOT_ZAI_ENV:-/mnt/ssd/openbot/zai.env}"
JARVIS_MODEL="${JARVIS_OPENCODE_MODEL:-zai-coding-plan/glm-5.3}"
JARVIS_AGENT_ID="${JARVIS_AGENT_ID:-}"
JARVIS_EFFORT="${JARVIS_REASONING_EFFORT:-medium}"
JARVIS_COMPUTER_USE="${JARVIS_COMPUTER_USE:-false}"
OC_CFG_SRC="${REMOTE_DIR}/config/openbot/opencode.json"
OC_CFG_DST="${HOME}/.config/opencode/opencode.json"
SYSTEMD_DROP="/etc/systemd/system/openbot.service.d/zai-env.conf"

log() { echo "[openbot-zai-jarvis] $*"; }

[[ -f "$ZAI_ENV" ]] || { log "HATA: $ZAI_ENV yok"; exit 1; }
[[ -f "$OC_CFG_SRC" ]] || { log "HATA: $OC_CFG_SRC yok"; exit 1; }
[[ -f "$DB" ]] || { log "HATA: openbot.db yok"; exit 1; }

mkdir -p "${HOME}/.config/opencode"
install -m 0600 "$OC_CFG_SRC" "$OC_CFG_DST"
log "opencode.json → $OC_CFG_DST"

if ! grep -q 'source.*zai.env' "${HOME}/.profile" 2>/dev/null; then
  echo "set -a; source ${ZAI_ENV}; set +a" >>"${HOME}/.profile"
fi

sudo tee "$SYSTEMD_DROP" >/dev/null <<EOF
[Service]
EnvironmentFile=-${ZAI_ENV}
EOF
sudo systemctl daemon-reload
log "systemd EnvironmentFile → $ZAI_ENV"

was_active=false
if systemctl is-active --quiet openbot.service 2>/dev/null; then
  was_active=true
  sudo systemctl stop openbot.service
fi

export DB JARVIS_MODEL JARVIS_AGENT_ID JARVIS_EFFORT JARVIS_COMPUTER_USE
python3 - <<'PY'
import json, os, sqlite3, sys
from datetime import datetime, timezone

db = os.environ["DB"]
model = os.environ["JARVIS_MODEL"]
aid = os.environ.get("JARVIS_AGENT_ID", "").strip()
effort = os.environ.get("JARVIS_EFFORT", "medium")
computer_use = os.environ.get("JARVIS_COMPUTER_USE", "false").strip().lower() == "true"

con = sqlite3.connect(db)
rows = [(r[0], r[1], json.loads(r[2])) for r in con.execute(
    "select agent_id, model, agent_json from projection_agents"
)]
if not rows:
    sys.exit("projection_agents boş")

pick = None
for agent_id, _, aj in rows:
    if aj.get("name") == "Jarvis" or (aid and aj.get("id") == aid):
        pick = (agent_id, aj)
        break
if not pick:
    pick = (rows[0][0], rows[0][2])

agent_id, aj = pick
aj["model"] = model
aj["provider"] = "opencode"
aj["reasoningEffort"] = effort
aj["computerUse"] = computer_use
now = datetime.now(timezone.utc).strftime("%Y-%m-%dT%H:%M:%S.%f")[:-3] + "Z"
aj["updatedAt"] = now
blob = json.dumps(aj, ensure_ascii=False, separators=(",", ":"))
con.execute(
    "update projection_agents set model=?, agent_json=?, updated_at=? where agent_id=?",
    (model, blob, now, agent_id),
)
con.commit()
print(agent_id, model, effort, aj["computerUse"])
PY

if [[ "$was_active" == true ]]; then
  sudo systemctl start openbot.service
  sleep 6
fi

log "Jarvis model: $JARVIS_MODEL (z.ai key: $ZAI_ENV)"