#!/usr/bin/env bash
# Hermes cron: Pi Gateway hata mesajlari (Türkçe, anlasilir, wrap yok).
set -euo pipefail
REMOTE_DIR="${REMOTE_DIR:-/home/${USER}/pi-gateway}"
log() { echo "[hermes-cron-patch] $*"; }

SCHEDULER="${HERMES_HOME:-$HOME/.hermes}/hermes-agent/cron/scheduler.py"
GATEWAY_RUN="${HERMES_HOME:-$HOME/.hermes}/hermes-agent/gateway/run.py"
PATCH_PY="${REMOTE_DIR}/scripts/lib/hermes-cron-patch.py"
GW_PATCH_PY="${REMOTE_DIR}/scripts/lib/hermes-gateway-patch.py"
TOKEN_PY="${REMOTE_DIR}/scripts/lib/hermes-token-patch.py"
CLASSIFIER="${HERMES_HOME:-$HOME/.hermes}/hermes-agent/agent/error_classifier.py"
[[ -f "$SCHEDULER" ]] || { log "HATA: scheduler yok"; exit 1; }
[[ -f "$PATCH_PY" ]] || { log "HATA: hermes-cron-patch.py yok"; exit 1; }

_patch_hash() {
  cat "$SCHEDULER" "$GATEWAY_RUN" "$CLASSIFIER" 2>/dev/null | sha256sum | awk '{print $1}'
}
_before="$(_patch_hash)"

python3 "$PATCH_PY" "$SCHEDULER"
if [[ -f "$GATEWAY_RUN" && -f "$GW_PATCH_PY" ]]; then
  python3 "$GW_PATCH_PY" "$GATEWAY_RUN" || log "WARN: gateway patch atlanamadi"
fi
if [[ -f "$CLASSIFIER" && -f "$TOKEN_PY" ]]; then
  python3 "$TOKEN_PY" "$CLASSIFIER" || log "WARN: 1308 token patch atlanamadi"
fi
if [[ "$(_patch_hash)" != "$_before" ]] && systemctl is-active --quiet hermes-gateway 2>/dev/null; then
  sudo systemctl restart hermes-gateway \
    && log "OK hermes-gateway restart (patch)" \
    || log "WARN: hermes-gateway restart basarisiz"
fi
log "Tamamlandi"
