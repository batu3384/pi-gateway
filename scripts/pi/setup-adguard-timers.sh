#!/usr/bin/env bash
# AdGuard filtre yenileme timer kurulumu (idempotent)
set -euo pipefail
REMOTE_DIR="${REMOTE_DIR:-/home/${USER}/pi-gateway}"
USER_NAME="${USER:-pi}"

install_unit() {
  local unit="$1"
  local src="$REMOTE_DIR/host/systemd/$unit"
  local dst="/etc/systemd/system/$unit"
  [[ -f "$src" ]] || return 0
  sed -e "s|/home/PI_USER/pi-gateway|${REMOTE_DIR}|g" \
      -e "s|/home/PI_USER|/home/${USER_NAME}|g" \
      -e "s|User=PI_USER|User=${USER_NAME}|g" \
      -e "s|Group=PI_USER|Group=${USER_NAME}|g" \
      "$src" | sudo tee "$dst" >/dev/null
}

for unit in \
  pi-gateway-adguard-filters.service \
  pi-gateway-adguard-filters.timer \
  pi-gateway-adguard-filters-failure.service; do
  install_unit "$unit"
done
sudo systemctl daemon-reload
sudo systemctl reset-failed pi-gateway-adguard-filters.service 2>/dev/null || true
sudo systemctl enable pi-gateway-adguard-filters.timer 2>/dev/null || true
sudo systemctl start pi-gateway-adguard-filters.timer 2>/dev/null || true
echo "[setup-adguard-timers] pi-gateway-adguard-filters.timer aktif"
