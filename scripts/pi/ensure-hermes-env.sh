#!/usr/bin/env bash
# Pi .env: HERMES_TELEGRAM_GATEWAY=true (hermes-gateway active ise).
set -euo pipefail
REMOTE_DIR="${REMOTE_DIR:-/home/${USER}/pi-gateway}"
ENV_FILE="${REMOTE_DIR}/.env"
log() { echo "[ensure-hermes-env] $*"; }

[[ -f "$ENV_FILE" ]] || { log "WARN: .env yok — atlandi"; exit 0; }

if grep -qE '^[[:space:]]*HERMES_TELEGRAM_GATEWAY=' "$ENV_FILE" 2>/dev/null; then
  if grep -qE '^[[:space:]]*HERMES_TELEGRAM_GATEWAY=false' "$ENV_FILE" 2>/dev/null \
    && systemctl is-active --quiet hermes-gateway 2>/dev/null; then
    sed -i 's/^HERMES_TELEGRAM_GATEWAY=.*/HERMES_TELEGRAM_GATEWAY=true/' "$ENV_FILE" 2>/dev/null \
      || sed -i '' 's/^HERMES_TELEGRAM_GATEWAY=.*/HERMES_TELEGRAM_GATEWAY=true/' "$ENV_FILE"
    log "OK: HERMES_TELEGRAM_GATEWAY=false -> true (hermes active)"
    exit 0
  fi
  log "HERMES_TELEGRAM_GATEWAY zaten tanimli"
  exit 0
fi

if systemctl is-enabled --quiet hermes-gateway 2>/dev/null \
  || systemctl is-active --quiet hermes-gateway 2>/dev/null; then
  :
else
  log "hermes-gateway yok/active degil — atlandi"
  exit 0
fi

printf '\n# Hermes gateway (auto)\nHERMES_TELEGRAM_GATEWAY=true\n' >>"$ENV_FILE"
log "OK: HERMES_TELEGRAM_GATEWAY=true eklendi"
