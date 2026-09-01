#!/usr/bin/env bash
# Hermes skills: /menu + ops komutlari
set -euo pipefail
REMOTE_DIR="${REMOTE_DIR:-/home/${USER}/pi-gateway}"
HERMES_SKILLS="${HERMES_HOME:-$HOME/.hermes}/skills"
log() { echo "[hermes-menu-skill] $*"; }

[[ "${HERMES_TELEGRAM_GATEWAY:-}" == "true" ]] \
  || systemctl is-active --quiet hermes-gateway 2>/dev/null \
  || { log "Hermes yok — atlandi"; exit 0; }

mkdir -p "$HERMES_SKILLS"
rm -rf "${HERMES_SKILLS}/pi-gateway-menu" "${HERMES_SKILLS}/paneller"

# Skills: config/hermes/skills/menu dns ssd backup recover
for skill in menu dns ssd backup recover; do
  src="${REMOTE_DIR}/config/hermes/skills/${skill}"
  dst="${HERMES_SKILLS}/${skill}"
  [[ -d "$src" ]] || continue
  rm -rf "$dst"
  cp -a "$src" "$dst"
  sed -i "s|__REMOTE_DIR__|${REMOTE_DIR}|g" "$dst/SKILL.md" 2>/dev/null \
    || sed -i '' "s|__REMOTE_DIR__|${REMOTE_DIR}|g" "$dst/SKILL.md"
  log "OK $dst"
done

if [[ -x "${REMOTE_DIR}/scripts/pi/telegram-menu.sh" ]]; then
  bash "${REMOTE_DIR}/scripts/pi/telegram-menu.sh" \
    && log "Telegram durum karti guncellendi" \
    || log "WARN: telegram-menu basarisiz"
fi
