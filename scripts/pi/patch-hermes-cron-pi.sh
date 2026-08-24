#!/usr/bin/env bash
# Hermes cron: Pi Gateway hata mesajlari (Türkçe, anlasilir, wrap yok).
set -euo pipefail
REMOTE_DIR="${REMOTE_DIR:-/home/${USER}/pi-gateway}"
log() { echo "[hermes-cron-patch] $*"; }

SCHEDULER="${HERMES_HOME:-$HOME/.hermes}/hermes-agent/cron/scheduler.py"
PATCH_PY="${REMOTE_DIR}/scripts/lib/hermes-cron-patch.py"
[[ -f "$SCHEDULER" ]] || { log "HATA: scheduler yok"; exit 1; }
[[ -f "$PATCH_PY" ]] || { log "HATA: hermes-cron-patch.py yok"; exit 1; }

python3 "$PATCH_PY" "$SCHEDULER"
log "Tamamlandi"
