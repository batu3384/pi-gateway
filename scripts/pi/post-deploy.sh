#!/usr/bin/env bash
# Deploy sonrasi tum yapilandirmalari sirayla uygular
set -euo pipefail

REMOTE_DIR="${REMOTE_DIR:-/home/${USER}/pi-gateway}"
SCRIPT_DIR="${REMOTE_DIR}/scripts/pi"

log() { echo "[post-deploy] $*"; }

run_step_critical() {
  local name="$1" script="$2"
  log ">> $name"
  REMOTE_DIR="$REMOTE_DIR" bash "$script" || {
    log "HATA: $name basarisiz"
    exit 1
  }
}

run_step_optional() {
  local name="$1" script="$2"
  log ">> $name"
  REMOTE_DIR="$REMOTE_DIR" bash "$script" || log "WARN: $name atlandi"
}

[[ -f "$REMOTE_DIR/.env" ]] || { log "HATA: .env yok"; exit 1; }

# shellcheck source=/dev/null
source "$REMOTE_DIR/.env"

run_step_optional "Config izinleri" "$SCRIPT_DIR/fix-config-perms.sh"

# SSD symlink (hybrid)
if [[ "${STORAGE_TYPE:-hybrid}" == "hybrid" || "${STORAGE_TYPE}" == "ssd-data" ]]; then
  log ">> SSD data symlink"
  REMOTE_DIR="$REMOTE_DIR" STORAGE_TYPE="${STORAGE_TYPE}" bash "$SCRIPT_DIR/ensure-data-symlink.sh" repair || {
    log "HATA: data symlink onarilamadi"
    exit 1
  }
fi

run_step_critical "AdGuard yapilandirma" "$SCRIPT_DIR/configure-adguard.sh"
run_step_optional "Host sertlestirme" "$SCRIPT_DIR/harden-host.sh"

if [[ "${ENABLE_FORGEJO:-true}" == "true" ]]; then
  run_step_optional "Forgejo admin" "$SCRIPT_DIR/setup-forgejo.sh"
fi

if [[ "${ENABLE_SYNCTHING:-true}" == "true" ]] && docker ps --format '{{.Names}}' | grep -q '^syncthing$'; then
  run_step_optional "Syncthing eslestirme" "$SCRIPT_DIR/setup-syncthing.sh"
  DEVICE_ID="$(docker exec syncthing cat /var/syncthing/config/config.xml 2>/dev/null | sed -n 's:.*<device id="\([^"]*\)".*:\1:p' | head -1 || true)"
  log "Syncthing Pi Device ID: ${DEVICE_ID:-bilinmiyor}"
  log "Syncthing UI: http://sync.${LAN_DOMAIN:-home}"
fi

if [[ "${ENABLE_RESTIC:-true}" == "true" ]]; then
  run_step_optional "Restic yedek" "$SCRIPT_DIR/restic-backup.sh"
fi

if [[ "${ENABLE_DOZZLE:-true}" == "true" ]]; then
  run_step_optional "Dozzle auth" "$SCRIPT_DIR/setup-dozzle.sh"
fi

if docker ps --format '{{.Names}}' | grep -q '^uptime-kuma$'; then
  run_step_optional "Uptime Kuma monitorler" "$SCRIPT_DIR/setup-uptime-kuma.sh"
fi

if command -v tailscale >/dev/null 2>&1 && tailscale status >/dev/null 2>&1; then
  run_step_optional "Tailscale uzaktan erisim" "$SCRIPT_DIR/setup-tailscale-remote.sh"
fi

if [[ "${ENABLE_CROWDSEC:-true}" == "true" ]]; then
  run_step_optional "CrowdSec" "$SCRIPT_DIR/setup-crowdsec.sh"
  run_step_optional "CrowdSec firewall bouncer" "$SCRIPT_DIR/setup-crowdsec-bouncer.sh"
fi

if [[ "${ENABLE_UFW:-true}" == "true" ]]; then
  run_step_optional "UFW firewall" "$SCRIPT_DIR/setup-firewall.sh"
fi

if [[ "${STORAGE_TYPE:-hybrid}" == "hybrid" || "${STORAGE_TYPE}" == "ssd-data" ]]; then
  if [[ "${ENABLE_DOCKER_SSD:-true}" == "true" ]] && [[ ! -f /mnt/ssd/.docker-data-root ]]; then
    run_step_optional "Docker SSD tasima" "$SCRIPT_DIR/setup-docker-ssd.sh"
  fi
fi

if [[ "${ENABLE_N8N:-true}" == "true" ]]; then
  run_step_optional "Sabah ozeti timer" "$SCRIPT_DIR/setup-morning-timer.sh"
  run_step_optional "n8n workflow (opsiyonel)" "$SCRIPT_DIR/setup-n8n-morning.sh"
fi

log "Post-deploy tamamlandi"
