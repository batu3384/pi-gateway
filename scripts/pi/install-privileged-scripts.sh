#!/usr/bin/env bash
# Root systemd unit'lerinin calistiracagi scriptleri root-owned lib'e kopyalar.
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
  scripts/pi/setup-docker-fallback.sh
  scripts/pi/ssd-hotplug-handler.sh
  scripts/lib/stack-health.sh
  scripts/lib/ssd-alive.sh
  scripts/lib/compose-profiles.sh
  scripts/lib/notify.sh
  scripts/lib/adguard-api.sh
  scripts/lib/ensure-data-symlink.sh
  scripts/pi/ssd-health.sh
)

run_root() {
  if [[ "$(id -u)" -eq 0 ]]; then
    "$@"
  else
    sudo "$@"
  fi
}

run_root mkdir -p "$LIB_DIR/scripts/pi" "$LIB_DIR/scripts/lib" /run/pi-gateway /usr/local/sbin

for rel in "${SCRIPTS[@]}"; do
  src="${REMOTE_DIR}/${rel}"
  dst="${LIB_DIR}/${rel}"
  if [[ ! -f "$src" ]]; then
    log "WARN: yok — $rel"
    continue
  fi
  run_root install -o root -g root -m 755 -D "$src" "$dst"
done

ssd_src="${REMOTE_DIR}/scripts/pi/setup-ssd-data.sh"
if [[ -f "$ssd_src" ]]; then
  run_root install -o root -g root -m 755 -D "$ssd_src" /usr/local/sbin/pi-setup-ssd-data.sh
  log "OK /usr/local/sbin/pi-setup-ssd-data.sh"
fi

# Deploy drift kontrolu
if command -v sha256sum >/dev/null 2>&1; then
  tmp_sha="$(mktemp)"
  (cd "$REMOTE_DIR" && sha256sum "${SCRIPTS[@]}" 2>/dev/null) >"$tmp_sha" || true
  run_root install -o root -g root -m 644 "$tmp_sha" "$LIB_DIR/.scripts-sha256"
  rm -f "$tmp_sha"
fi

log "OK root-owned lib: $LIB_DIR"
