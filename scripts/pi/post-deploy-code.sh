#!/usr/bin/env bash
# Code deploy: repo sync + privileged lib + Hermes/notify hot path.
# Skip: bootstrap, compose canary/recreate, UFW/n8n/Kuma/CrowdSec full post-deploy.
set -euo pipefail
REMOTE_DIR="${REMOTE_DIR:-/home/${USER}/pi-gateway}"
SCRIPT_DIR="${REMOTE_DIR}/scripts/pi"
log() { echo "[post-deploy-code] $*"; }

[[ -f "$REMOTE_DIR/.env" ]] || { log "HATA: .env yok"; exit 1; }
# shellcheck source=../lib/env-file.sh
source "${SCRIPT_DIR}/../lib/env-file.sh"
read_remote_dotenv || { log "HATA: .env parse"; exit 1; }

soft() {
  local name="$1" script="$2"
  log ">> $name"
  if REMOTE_DIR="$REMOTE_DIR" bash "$script"; then
    return 0
  fi
  log "WARN: $name basarisiz — devam"
  return 0
}

crit() {
  local name="$1" script="$2"
  log ">> $name"
  REMOTE_DIR="$REMOTE_DIR" bash "$script" || {
    log "HATA: $name"
    exit 1
  }
}

crit "Privileged scripts" "$SCRIPT_DIR/install-privileged-scripts.sh"
soft "Config izinleri" "$SCRIPT_DIR/fix-config-perms.sh"

# Hermes / Telegram outbox hot path (sohbet + alarm metinleri)
if [[ "${HERMES_TELEGRAM_GATEWAY:-}" == "true" ]]; then
  soft "Hermes telegram patch" "$SCRIPT_DIR/patch-hermes-telegram-pi.sh"
  soft "Hermes cron patch" "$SCRIPT_DIR/patch-hermes-cron-pi.sh"
  soft "Hermes config" "$SCRIPT_DIR/patch-hermes-config-pi.sh"
  soft "Hermes cron jobs" "$SCRIPT_DIR/setup-hermes-cron.sh"
  # Menu skill + durum kartı: full deploy / DEPLOY_CODE_MENU=true
  if [[ "${DEPLOY_CODE_MENU:-false}" == "true" ]]; then
    soft "Hermes menu skill" "$SCRIPT_DIR/setup-hermes-menu-skill.sh"
  fi
fi

soft "Notify transition self-check" "$SCRIPT_DIR/test-notify-transitions.sh"
log "Code post-deploy tamamlandi"
