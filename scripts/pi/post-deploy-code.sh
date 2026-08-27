#!/usr/bin/env bash
# Code deploy: repo sync + privileged lib + Hermes/notify hot path.
# Skip: bootstrap, compose canary, UFW/Kuma/CrowdSec full post-deploy.
# n8n: yalnız NODES_EXCLUDE henüz uygulanmadıysa recreate.
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
soft "Host sertlestirme" "$SCRIPT_DIR/harden-host.sh"

if docker ps --format '{{.Names}}' 2>/dev/null | grep -qx caddy; then
  log ">> Caddy reload"
  docker exec caddy caddy reload --config /etc/caddy/Caddyfile \
    || log "WARN: caddy reload"
fi
if docker ps --format '{{.Names}}' 2>/dev/null | grep -qx n8n; then
  n8n_ex="$(docker inspect n8n --format '{{range .Config.Env}}{{println .}}{{end}}' 2>/dev/null | grep '^NODES_EXCLUDE=' || true)"
  if [[ "$n8n_ex" == *n8n-nodes-base.ssh* ]]; then
    log "n8n NODES_EXCLUDE zaten ssh kapali — recreate yok"
  else
    log ">> n8n recreate (NODES_EXCLUDE ssh)"
    (cd "$REMOTE_DIR/compose" && docker compose --env-file ../.env up -d --no-deps n8n) \
      || log "WARN: n8n up"
  fi
fi

# Hermes / Telegram outbox hot path (sohbet + alarm metinleri)
if [[ "${HERMES_TELEGRAM_GATEWAY:-}" == "true" ]]; then
  soft "Hermes telegram patch" "$SCRIPT_DIR/patch-hermes-telegram-pi.sh"
  soft "Hermes cron patch" "$SCRIPT_DIR/patch-hermes-cron-pi.sh"
  soft "Hermes config" "$SCRIPT_DIR/patch-hermes-config-pi.sh"
  soft "Hermes cron jobs" "$SCRIPT_DIR/setup-hermes-cron.sh"
  # SOUL + ops skill + ölü skill disable (her code deploy)
  soft "Hermes identity" "$SCRIPT_DIR/setup-hermes-identity.sh"
  # Menu skill + durum kartı: full deploy / DEPLOY_CODE_MENU=true
  if [[ "${DEPLOY_CODE_MENU:-false}" == "true" ]]; then
    soft "Hermes menu skill" "$SCRIPT_DIR/setup-hermes-menu-skill.sh"
  fi
  if systemctl is-active --quiet hermes-gateway 2>/dev/null; then
    sudo systemctl restart hermes-gateway 2>/dev/null \
      && log "hermes-gateway restart (SOUL/ops)" \
      || log "WARN: hermes-gateway restart"
  fi
fi

soft "Home ops timers" "$SCRIPT_DIR/setup-home-ops-timers.sh"
soft "Notify transition self-check" "$SCRIPT_DIR/test-notify-transitions.sh"
log "Code post-deploy tamamlandi"
