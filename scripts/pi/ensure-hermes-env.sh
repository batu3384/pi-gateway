#!/usr/bin/env bash
# Pi .env: HERMES_TELEGRAM_GATEWAY=true (hermes-gateway active ise).
set -euo pipefail
REMOTE_DIR="${REMOTE_DIR:-/home/${USER}/pi-gateway}"
ENV_FILE="${REMOTE_DIR}/.env"
log() { echo "[ensure-hermes-env] $*"; }

[[ -f "$ENV_FILE" ]] || { log "WARN: .env yok — atlandi"; exit 0; }

if grep -qE '^[[:space:]]*HERMES_TELEGRAM_GATEWAY=' "$ENV_FILE" 2>/dev/null; then
  log "HERMES_TELEGRAM_GATEWAY zaten tanimli"
  exit 0
fi

if ! systemctl is-active --quiet hermes-gateway 2>/dev/null; then
  log "hermes-gateway active degil — atlandi"
  exit 0
fi

printf '\n# Hermes gateway (auto)\nHERMES_TELEGRAM_GATEWAY=true\n' >>"$ENV_FILE"
log "OK: HERMES_TELEGRAM_GATEWAY=true eklendi"
