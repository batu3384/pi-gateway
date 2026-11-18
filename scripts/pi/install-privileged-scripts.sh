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
  scripts/pi/apply-adguard-filters.sh
  scripts/pi/apply-adguard-dns.sh
  scripts/pi/ensure-adguard-blocking.sh
  scripts/pi/health-check.sh
  scripts/pi/check-sd-health.sh
  scripts/pi/setup-docker-fallback.sh
  scripts/pi/setup-docker-ssd.sh
  scripts/pi/ssd-hotplug-handler.sh
  scripts/pi/setup-ssd-data.sh
  scripts/lib/stack-health.sh
  scripts/lib/env-file.sh
  scripts/lib/unified-login.sh
  scripts/lib/modem_inventory.py
  scripts/lib/ssd-alive.sh
  scripts/lib/ssd-usb-metrics.py
  scripts/lib/zte-h3600p.py
  scripts/lib/compose-profiles.sh
  scripts/pi/export-gateway-state.sh
  scripts/pi/export-adguard-metrics.sh
  scripts/pi/push-slo-heartbeat.sh
  scripts/pi/repair-docker-network-store.sh
  scripts/pi/repair-post-ssd-recovery.sh
  scripts/pi/repair-adguard-bbolt.sh
  scripts/pi/setup-firewall.sh
  scripts/pi/setup-dozzle.sh
  scripts/pi/fix-config-perms.sh
  scripts/pi/ensure-netalert-db-access.sh
  scripts/pi/wait-adguard-dns.sh
  scripts/pi/sync-modem-inventory.sh
  scripts/lib/adguard-metrics.py
  scripts/lib/sync-adguard-clients.py
  scripts/lib/adguard-filters.py
  scripts/lib/unbound-dnssec.sh
  scripts/lib/gateway-probes.py
  scripts/lib/netalert-devices.py
  scripts/lib/notify.sh
  scripts/lib/reset-gateway-units.sh
  scripts/pi/boot-notify.sh
  scripts/pi/hermes-inbox-up-notify.sh
  scripts/lib/bulletin-slo.py
  scripts/lib/hermes-token-slo.py
  scripts/lib/hermes-session-hygiene.py
  scripts/lib/reap-dead-docker-scopes.sh
  scripts/lib/adguard-api.sh
  scripts/lib/dns-dot-proxy.py
  scripts/pi/dns-host-fallback.sh
  scripts/lib/ensure-data-symlink.sh
  scripts/pi/ssd-fsck.sh
  scripts/pi/ssd-health.sh
  scripts/pi/prune-sd-space.sh
  scripts/pi/setup-tailscale-panel-ports.sh
  scripts/pi/sync-crowdsec-ufw.sh
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
if [[ "$_pi_state_user" == "root" && "$REMOTE_DIR" =~ /home/([^/]+)/ ]]; then
  _pi_state_user="${BASH_REMATCH[1]}"
fi
run_root mkdir -p /var/lib/pi-gateway /var/lib/pi-gateway/metrics /var/lib/pi-gateway/public
run_root chown "${_pi_state_user}:${_pi_state_user}" \
  /var/lib/pi-gateway /var/lib/pi-gateway/metrics /var/lib/pi-gateway/public
run_root chmod 775 /var/lib/pi-gateway /var/lib/pi-gateway/metrics
run_root chmod 755 /var/lib/pi-gateway/public
if [[ ! -f /var/lib/pi-gateway/public/state.json ]]; then
  _pub_tmp="$(mktemp)"
  if [[ -f /var/lib/pi-gateway/state.json ]]; then
    cp /var/lib/pi-gateway/state.json "$_pub_tmp"
  else
    printf '{"ts":"","ssd_mount_healthy":1}\n' >"$_pub_tmp"
  fi
  run_root install -o "$_pi_state_user" -g "$_pi_state_user" -m 644 \
    "$_pub_tmp" /var/lib/pi-gateway/public/state.json
  rm -f "$_pub_tmp"
fi

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

install_unit() {
  local unit="$1"
  local src="${REMOTE_DIR}/host/systemd/${unit}"
  local dst="/etc/systemd/system/${unit}"
  local tmp owner
  [[ -f "$src" ]] || {
    log "HATA: unit yok — $src"
    exit 1
  }
  owner="${SUDO_USER:-${USER:-pi}}"
  if [[ "$owner" == "root" && "$REMOTE_DIR" =~ /home/([^/]+)/ ]]; then
    owner="${BASH_REMATCH[1]}"
  fi
  tmp="$(mktemp)"
  sed -e "s|/home/PI_USER/pi-gateway|${REMOTE_DIR}|g" \
      -e "s|/home/PI_USER|/home/${owner}|g" \
      -e "s|User=PI_USER|User=${owner}|g" \
      -e "s|Group=PI_USER|Group=${owner}|g" \
      -e "s|Environment=PI_USER=PI_USER|Environment=PI_USER=${owner}|g" \
      "$src" >"$tmp"
  run_root install -o root -g root -m 644 "$tmp" "$dst"
  rm -f "$tmp"
}

for unit in \
  pi-gateway-health.service pi-gateway-health.timer \
  pi-gateway-health-failure.service \
  pi-gateway-container-watchdog.service pi-gateway-container-watchdog.timer \
  pi-data-symlink.timer pi-data-symlink-repair.service \
  pi-gateway-dns-fallback.service \
  pi-gateway-ts-panel-ports.service \
  pi-ssd-data.service
do
  install_unit "$unit"
done
run_root systemctl disable pi-gateway-dns-fallback.service 2>/dev/null || true
run_root systemctl daemon-reload
run_root systemctl reset-failed pi-gateway-dns-fallback.service 2>/dev/null || true
run_root systemctl restart pi-gateway-health.timer \
  pi-gateway-container-watchdog.timer pi-data-symlink.timer 2>/dev/null || true
log "OK systemd health/watchdog/fallback units"

if [[ -f "${REMOTE_DIR}/host/udev/99-pi-gateway-jmicron.rules" ]]; then
  run_root install -o root -g root -m 644 \
    "${REMOTE_DIR}/host/udev/99-pi-gateway-jmicron.rules" \
    /etc/udev/rules.d/99-pi-gateway-jmicron.rules
  run_root udevadm control --reload-rules 2>/dev/null || true
  log "OK udev 99-pi-gateway-jmicron.rules"
fi
