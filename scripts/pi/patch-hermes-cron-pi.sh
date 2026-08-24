#!/usr/bin/env bash
# Hermes cron: Pi Gateway hata mesajlari (Türkçe, anlasilir, wrap yok).
set -euo pipefail
REMOTE_DIR="${REMOTE_DIR:-/home/${USER}/pi-gateway}"
log() { echo "[hermes-cron-patch] $*"; }

SCHEDULER="${HERMES_HOME:-$HOME/.hermes}/hermes-agent/cron/scheduler.py"
GATEWAY_RUN="${HERMES_HOME:-$HOME/.hermes}/hermes-agent/gateway/run.py"
PATCH_PY="${REMOTE_DIR}/scripts/lib/hermes-cron-patch.py"
GW_PATCH_PY="${REMOTE_DIR}/scripts/lib/hermes-gateway-patch.py"
[[ -f "$SCHEDULER" ]] || { log "HATA: scheduler yok"; exit 1; }
[[ -f "$PATCH_PY" ]] || { log "HATA: hermes-cron-patch.py yok"; exit 1; }

python3 "$PATCH_PY" "$SCHEDULER"
if [[ -f "$GATEWAY_RUN" && -f "$GW_PATCH_PY" ]]; then
  python3 "$GW_PATCH_PY" "$GATEWAY_RUN" || log "WARN: gateway patch atlanamadi"
fi
log "Tamamlandi"
