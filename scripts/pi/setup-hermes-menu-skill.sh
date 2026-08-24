#!/usr/bin/env bash
# Hermes skill: /menu -> hermes-menu.sh (panel linkleri).
set -euo pipefail
REMOTE_DIR="${REMOTE_DIR:-/home/${USER}/pi-gateway}"
HERMES_SKILLS="${HERMES_HOME:-$HOME/.hermes}/skills"
SRC="${REMOTE_DIR}/config/hermes/skills/pi-gateway-menu"
DST="${HERMES_SKILLS}/pi-gateway-menu"
log() { echo "[hermes-menu-skill] $*"; }

[[ "${HERMES_TELEGRAM_GATEWAY:-}" == "true" ]] \
  || systemctl is-active --quiet hermes-gateway 2>/dev/null \
  || { log "Hermes yok — atlandi"; exit 0; }

[[ -d "$SRC" ]] || { log "HATA: $SRC yok"; exit 1; }
mkdir -p "$HERMES_SKILLS"
rm -rf "$DST"
cp -a "$SRC" "$DST"
sed -i "s|__REMOTE_DIR__|${REMOTE_DIR}|g" "$DST/SKILL.md" 2>/dev/null \
  || sed -i '' "s|__REMOTE_DIR__|${REMOTE_DIR}|g" "$DST/SKILL.md"
log "OK $DST"

if [[ -x "${REMOTE_DIR}/scripts/pi/telegram-menu.sh" ]]; then
  bash "${REMOTE_DIR}/scripts/pi/telegram-menu.sh" \
    && log "Telegram bot commands + menu guncellendi" \
    || log "WARN: telegram-menu basarisiz"
fi
