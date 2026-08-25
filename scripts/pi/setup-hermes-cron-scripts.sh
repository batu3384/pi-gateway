#!/usr/bin/env bash
# Hermes cron: ~/.hermes/scripts/ altina pi-gateway wrapper betikleri.
set -euo pipefail
REMOTE_DIR="${REMOTE_DIR:-/home/${USER}/pi-gateway}"
HERMES_SCRIPTS="${HERMES_HOME:-$HOME/.hermes}/scripts"
log() { echo "[hermes-cron-scripts] $*"; }

_install() {
  local wrapper="$1" script="$2"
  local path="${HERMES_SCRIPTS}/${wrapper}"
  cat >"$path" <<EOF
#!/usr/bin/env bash
# Pi Gateway — Hermes cron wrapper (setup-hermes-cron-scripts.sh)
set -euo pipefail
REMOTE_DIR="${REMOTE_DIR}"
export REMOTE_DIR
exec "\${REMOTE_DIR}/scripts/pi/${script}"
EOF
  chmod +x "$path"
  log "OK ${wrapper}"
}

mkdir -p "$HERMES_SCRIPTS"
[[ -d "${REMOTE_DIR}/scripts/pi" ]] || { log "HATA: ${REMOTE_DIR}/scripts/pi yok"; exit 1; }

_install pi-fx-quote.sh fx-quote.sh

log "Tamamlandi — ${HERMES_SCRIPTS}"
# Eski wrapper kalintilari
rm -f "${HERMES_SCRIPTS}/pi-watchdog.sh" \
  "${HERMES_SCRIPTS}/pi-netalert-newdev.sh" \
  "${HERMES_SCRIPTS}/pi-netalert-offline.sh" 2>/dev/null || true
