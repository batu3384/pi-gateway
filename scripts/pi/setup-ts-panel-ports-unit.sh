#!/usr/bin/env bash
# Install + enable oneshot: Tailscale IP:PORT DNAT (panel asset 404 fix)
set -euo pipefail
REMOTE_DIR="${REMOTE_DIR:-/home/${USER}/pi-gateway}"
log() { echo "[ts-panel-ports-unit] $*"; }
unit=pi-gateway-ts-panel-ports.service
src="$REMOTE_DIR/host/systemd/$unit"
[[ -f "$src" ]] || { log "HATA: $src yok"; exit 1; }
_owner="${PI_USER:-${SUDO_USER:-${USER:-pi}}}"
[[ "$_owner" == "root" && "$REMOTE_DIR" =~ /home/([^/]+)/ ]] && _owner="${BASH_REMATCH[1]}"
_tmp="$(mktemp)"
sed -e "s|/home/PI_USER/pi-gateway|${REMOTE_DIR}|g" \
    -e "s|/home/PI_USER|/home/${_owner}|g" \
    -e "s|User=PI_USER|User=${_owner}|g" \
    -e "s|Group=PI_USER|Group=${_owner}|g" \
    -e "s|Environment=PI_USER=PI_USER|Environment=PI_USER=${_owner}|g" \
    "$src" >"$_tmp"
sudo install -o root -g root -m 644 "$_tmp" "/etc/systemd/system/$unit"
rm -f "$_tmp"
sudo systemctl daemon-reload
sudo systemctl enable "$unit"
# restart: RemainAfterExit oneshot'u tek seferde canli uygular
sudo systemctl restart "$unit" || {
  log "HATA: Tailscale panel portlari uygulanamadi"
  exit 1
}
log "Aktif: $unit"
