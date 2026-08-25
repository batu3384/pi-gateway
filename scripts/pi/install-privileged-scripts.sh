#!/usr/bin/env bash
# Root systemd unit'lerinin calistiracagi scriptleri root-owned lib'e kopyalar.
set -euo pipefail

REMOTE_DIR="${REMOTE_DIR:-/home/${USER}/pi-gateway}"
LIB_DIR="${PI_GATEWAY_LIB_DIR:-/usr/local/lib/pi-gateway}"

log() { echo "[install-priv] $*"; }

SCRIPTS=(
  scripts/pi/recover-readonly-root.sh
  scripts/pi/recover-stack.sh
  scripts/pi/recover-compose-up.sh
  scripts/pi/ensure-ssd-fstab.sh
  scripts/pi/ensure-data-symlink.sh
  scripts/pi/apply-adguard-rewrites.sh
  scripts/pi/health-check.sh
  scripts/pi/check-sd-health.sh
  scripts/pi/setup-docker-fallback.sh
  scripts/pi/ssd-hotplug-handler.sh
  scripts/pi/setup-ssd-data.sh
  scripts/lib/stack-health.sh
  scripts/lib/env-file.sh
  scripts/lib/ssd-alive.sh
  scripts/lib/compose-profiles.sh
  scripts/lib/notify.sh
  scripts/lib/bulletin-slo.py
  scripts/lib/hermes-token-slo.py
  scripts/lib/hermes-session-hygiene.py
  scripts/lib/reap-dead-docker-scopes.sh
  scripts/lib/adguard-api.sh
  scripts/lib/ensure-data-symlink.sh
  scripts/pi/ssd-health.sh
  scripts/pi/prune-sd-space.sh
)

run_root() {
  if [[ "$(id -u)" -eq 0 ]]; then
    "$@"
  else
    sudo "$@"
  fi
}

run_root mkdir -p "$LIB_DIR/scripts/pi" "$LIB_DIR/scripts/lib" /run/pi-gateway /usr/local/sbin
_pi_state_user="${SUDO_USER:-${USER:-pi}}"
run_root mkdir -p /var/lib/pi-gateway
run_root chown "${_pi_state_user}:${_pi_state_user}" /var/lib/pi-gateway
run_root chmod 775 /var/lib/pi-gateway

install_verified() {
  local src="$1" dst="$2" before after
  [[ -f "$src" ]] || {
    log "HATA: privileged kaynak yok — $src"
    exit 1
  }
  [[ -z "$(find "$src" -maxdepth 0 -perm /022 2>/dev/null)" ]] || {
    log "HATA: group/world-writable kaynak reddedildi — $src"
    exit 1
  }
  before="$(sha256sum "$src" | awk '{print $1}')"
  [[ -n "$before" ]] || {
    log "HATA: kaynak hash alinamadi — $src"
    exit 1
  }
  run_root install -o root -g root -m 755 -D "$src" "$dst"
  after="$(run_root sha256sum "$dst" | awk '{print $1}')"
  [[ "$after" == "$before" ]] || {
    log "HATA: install hash uyusmazligi — $src"
    exit 1
  }
  [[ "$(sha256sum "$src" | awk '{print $1}')" == "$before" ]] || {
    log "HATA: kaynak install sirasinda degisti — $src"
    exit 1
  }
}

for rel in "${SCRIPTS[@]}"; do
  src="${REMOTE_DIR}/${rel}"
  dst="${LIB_DIR}/${rel}"
  install_verified "$src" "$dst"
done

ssd_src="${REMOTE_DIR}/scripts/pi/setup-ssd-data.sh"
if [[ -f "$ssd_src" ]]; then
  run_root install -o root -g root -m 755 -D \
    "$LIB_DIR/scripts/pi/setup-ssd-data.sh" /usr/local/sbin/pi-setup-ssd-data.sh
  log "OK /usr/local/sbin/pi-setup-ssd-data.sh"
fi

# Deploy drift kontrolu + install sonrasi hash (systemd path integrity)
if command -v sha256sum >/dev/null 2>&1; then
  tmp_sha="$(mktemp)"
  (cd "$REMOTE_DIR" && sha256sum "${SCRIPTS[@]}") >"$tmp_sha"
  run_root install -o root -g root -m 644 "$tmp_sha" "$LIB_DIR/.scripts-sha256"
  rm -f "$tmp_sha"
  tmp_inst="$(mktemp)"
  (
    cd "$LIB_DIR" || exit 0
    sha256sum "${SCRIPTS[@]}" 2>/dev/null
  ) >"$tmp_inst"
  run_root install -o root -g root -m 644 "$tmp_inst" "$LIB_DIR/.installed-sha256"
  rm -f "$tmp_inst"
fi

log "OK root-owned lib: $LIB_DIR"
