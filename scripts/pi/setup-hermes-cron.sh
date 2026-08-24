#!/usr/bin/env bash
# Hermes cron job şablonlarını ~/.hermes/cron/jobs.json ile birleştir.
set -euo pipefail
REMOTE_DIR="${REMOTE_DIR:-/home/${USER}/pi-gateway}"
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
_PG_ENV_LIB="${SCRIPT_DIR}/../lib/env-file.sh"
PG_SCRIPT_NAME="$(basename "$0")"
# shellcheck source=../lib/env-file.sh
source "${_PG_ENV_LIB:?}"
read_remote_dotenv || { echo "[${PG_SCRIPT_NAME}] HATA: .env dotenv parser hatasi" >&2; exit 1; }
TEMPLATE="${REMOTE_DIR}/config/hermes/cron-jobs.template.json"
MERGE="${SCRIPT_DIR}/../lib/hermes-cron-merge.py"
HERMES_HOME="${HERMES_HOME:-$HOME/.hermes}"
LIVE="${HERMES_HOME}/cron/jobs.json"
log() { echo "[hermes-cron-setup] $*"; }

if [[ "${HERMES_TELEGRAM_GATEWAY:-}" != "true" ]] \
  && systemctl is-active --quiet hermes-gateway 2>/dev/null; then
  export HERMES_TELEGRAM_GATEWAY=true
fi
[[ "${HERMES_TELEGRAM_GATEWAY:-}" == "true" ]] || { log "HERMES_TELEGRAM_GATEWAY!=true — atlandi"; exit 0; }
[[ -f "$TEMPLATE" ]] || { log "HATA: $TEMPLATE yok"; exit 1; }
[[ -f "$MERGE" ]] || { log "HATA: $MERGE yok"; exit 1; }

bash "$SCRIPT_DIR/setup-hermes-cron-scripts.sh"
[[ -x "$SCRIPT_DIR/patch-hermes-cron-pi.sh" ]] && bash "$SCRIPT_DIR/patch-hermes-cron-pi.sh" || true

mkdir -p "$(dirname "$LIVE")"
python3 "$MERGE" \
  --template "$TEMPLATE" \
  --live "$LIVE" \
  --remote-dir "$REMOTE_DIR" \
  --pi-user "${USER}"

# 07:00 pano merge sonrasi 08:00 leftover timer kapat
if [[ -x "$SCRIPT_DIR/setup-morning-timer.sh" ]]; then
  bash "$SCRIPT_DIR/setup-morning-timer.sh" || log "WARN: sabah timer kesisti atlandi"
fi

log "Tamamlandi — $LIVE"
