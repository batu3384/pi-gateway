#!/usr/bin/env bash
# Hermes config: cron/bülten timeout ve z.ai stale_timeout (Pi).
set -euo pipefail
REMOTE_DIR="${REMOTE_DIR:-/home/${USER}/pi-gateway}"
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
_PG_ENV_LIB="${SCRIPT_DIR}/../lib/env-file.sh"
PG_SCRIPT_NAME="$(basename "$0")"
# shellcheck source=../lib/env-file.sh
source "${_PG_ENV_LIB:?}"
read_remote_dotenv || { echo "[${PG_SCRIPT_NAME}] HATA: .env dotenv parser hatasi" >&2; exit 1; }
log() { echo "[hermes-config-patch] $*"; }

if [[ "${HERMES_TELEGRAM_GATEWAY:-}" != "true" ]] \
  && systemctl is-active --quiet hermes-gateway 2>/dev/null; then
  export HERMES_TELEGRAM_GATEWAY=true
fi
[[ "${HERMES_TELEGRAM_GATEWAY:-}" == "true" ]] || { log "HERMES_TELEGRAM_GATEWAY!=true — atlandi"; exit 0; }

hermes_bin="${HOME}/.local/bin/hermes"
[[ -x "$hermes_bin" ]] || { log "hermes yok — atlandi"; exit 0; }

set_cfg() {
  local key="$1" val="$2"
  "$hermes_bin" config set "$key" "$val" >/dev/null 2>&1 \
    && log "OK $key=$val" \
    || log "WARN: $key ayarlanamadi"
}

set_cfg "providers.zai.models.glm-5.3.stale_timeout_seconds" "${HERMES_STALE_TIMEOUT_SEC:-600}"
set_cfg "cron.bot_chat_delivery_timeout_seconds" "${HERMES_CRON_DELIVERY_TIMEOUT_SEC:-900}"
set_cfg "model.inactivity_timeout" "${HERMES_MODEL_INACTIVITY_TIMEOUT:-300}"
set_cfg "model.timeout" "${HERMES_MODEL_TIMEOUT:-180}"
set_cfg "code_execution.max_tool_calls" "${HERMES_MAX_TOOL_CALLS:-45}"
set_cfg "streaming.enabled" "${HERMES_STREAMING:-true}"
set_cfg "cron.wrap_response" "false"

log "Tamamlandi"
