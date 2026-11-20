#!/usr/bin/env bash
# Filo rutinleri. Eski Jarvis bülten ve 18:54 FX timer kapalı kalır.
set -euo pipefail
REMOTE_DIR="${REMOTE_DIR:-/home/${USER}/pi-gateway}"
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=../lib/env-file.sh
source "${SCRIPT_DIR}/../lib/env-file.sh"
# shellcheck source=../lib/openbot-paths.sh
source "${SCRIPT_DIR}/../lib/openbot-paths.sh"
read_remote_dotenv || true

PY="${SCRIPT_DIR}/sync-fleet-routines.py"
DATA_ROOT="$(openbot_data_root)"
STATE_DIR="$(openbot_state_dir)"
export OPENBOT_DATA_ROOT="$DATA_ROOT" OPENBOT_STATE_DIR="$STATE_DIR"

log() { echo "[jarvis-routines] $*"; }

chmod +x "$PY" "${SCRIPT_DIR}/pi-fleet-watchdog.sh" "${SCRIPT_DIR}/jarvis-send.sh" 2>/dev/null || true

set +e
python3 "$PY" --check
rc=$?
set -e
if [[ "$rc" -eq 10 ]]; then
  if [[ "${OPENBOT_FLEET_SYNC_APPLY:-}" == "1" ]]; then
    log "filo rutin farkı — openbot.service durduruluyor"
    sudo systemctl stop openbot.service
    OPENBOT_FLEET_SYNC_APPLY=1 python3 "$PY" --apply
    sudo systemctl start openbot.service
    log "filo rutinleri yazıldı"
  else
    log "filo rutin farkı (UI korunur). Zorla: OPENBOT_FLEET_SYNC_APPLY=1"
  fi
elif [[ "$rc" -eq 0 ]]; then
  log "filo rutinleri güncel"
else
  exit "$rc"
fi

for unit in jarvis-bulletin-morning jarvis-bulletin-fx jarvis-bulletin-evening \
  jarvis-bulletin-night jarvis-fx-prepare; do
  sudo systemctl disable --now "${unit}.timer" 2>/dev/null || true
done