#!/usr/bin/env bash
# Root systemd unit'lerinin calistiracagi scriptleri root-owned lib'e kopyalar.
# Repo (~/pi-gateway) kullanici yazilabilir; privilege escalation riskini keser.
set -euo pipefail

REMOTE_DIR="${REMOTE_DIR:-/home/${USER}/pi-gateway}"
LIB_DIR="${PI_GATEWAY_LIB_DIR:-/usr/local/lib/pi-gateway}"

log() { echo "[install-priv] $*"; }

SCRIPTS=(
  scripts/pi/recover-readonly-root.sh
  scripts/pi/recover-compose-up.sh
  scripts/pi/ensure-ssd-fstab.sh
  scripts/pi/ensure-data-symlink.sh
  scripts/pi/stack-watchdog.sh
  scripts/pi/apply-adguard-rewrites.sh
  scripts/pi/health-check.sh
  scripts/pi/check-sd-health.sh
  scripts/lib/stack-health.sh
  scripts/lib/compose-profiles.sh
  scripts/lib/notify.sh
  scripts/lib/adguard-api.sh
  scripts/lib/ensure-data-symlink.sh
)

run_root() {
  if [[ "$(id -u)" -eq 0 ]]; then
    "$@"
  else
    sudo "$@"
  fi
}

run_root mkdir -p "$LIB_DIR/scripts/pi" "$LIB_DIR/scripts/lib"

for rel in "${SCRIPTS[@]}"; do
  src="${REMOTE_DIR}/${rel}"
  dst="${LIB_DIR}/${rel}"
  if [[ ! -f "$src" ]]; then
    log "WARN: yok — $rel"
    continue
  fi
  run_root install -o root -g root -m 755 -D "$src" "$dst"
done

# recover/watchdog REMOTE_DIR'deki .env + compose'u kullanmaya devam eder
log "OK root-owned lib: $LIB_DIR"
