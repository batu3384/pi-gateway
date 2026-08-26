#!/usr/bin/env bash
# Hermes skill: /menu (+ Paneller reply keyboard) -> hermes-menu.sh
set -euo pipefail
REMOTE_DIR="${REMOTE_DIR:-/home/${USER}/pi-gateway}"
HERMES_SKILLS="${HERMES_HOME:-$HOME/.hermes}/skills"
SRC_MENU="${REMOTE_DIR}/config/hermes/skills/menu"
SRC_PANEL="${REMOTE_DIR}/config/hermes/skills/paneller"
DST_MENU="${HERMES_SKILLS}/menu"
DST_PANEL="${HERMES_SKILLS}/paneller"
log() { echo "[hermes-menu-skill] $*"; }

[[ "${HERMES_TELEGRAM_GATEWAY:-}" == "true" ]] \
  || systemctl is-active --quiet hermes-gateway 2>/dev/null \
  || { log "Hermes yok — atlandi"; exit 0; }

[[ -d "$SRC_MENU" ]] || { log "HATA: $SRC_MENU yok"; exit 1; }
mkdir -p "$HERMES_SKILLS"
# Eski ad kalintisi
rm -rf "${HERMES_SKILLS}/pi-gateway-menu" "$DST_MENU" "$DST_PANEL"
cp -a "$SRC_MENU" "$DST_MENU"
sed -i "s|__REMOTE_DIR__|${REMOTE_DIR}|g" "$DST_MENU/SKILL.md" 2>/dev/null \
  || sed -i '' "s|__REMOTE_DIR__|${REMOTE_DIR}|g" "$DST_MENU/SKILL.md"
if [[ -d "$SRC_PANEL" ]]; then
  cp -a "$SRC_PANEL" "$DST_PANEL"
  sed -i "s|__REMOTE_DIR__|${REMOTE_DIR}|g" "$DST_PANEL/SKILL.md" 2>/dev/null \
    || sed -i '' "s|__REMOTE_DIR__|${REMOTE_DIR}|g" "$DST_PANEL/SKILL.md"
fi
log "OK $DST_MENU ${DST_PANEL:+$DST_PANEL}"

if [[ -x "${REMOTE_DIR}/scripts/pi/telegram-menu.sh" ]]; then
  bash "${REMOTE_DIR}/scripts/pi/telegram-menu.sh" \
    && log "Telegram panel menusu + Paneller butonu guncellendi" \
    || log "WARN: telegram-menu basarisiz"
fi
