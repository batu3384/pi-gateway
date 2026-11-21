#!/usr/bin/env bash
# Install weekly SSD SMART check timer
set -euo pipefail
REMOTE_DIR="${REMOTE_DIR:-/home/${USER}/pi-gateway}"
log() { echo "[ssd-smart-timer] $*"; }
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=../lib/env-file.sh
source "$SCRIPT_DIR/../lib/env-file.sh"
read_remote_dotenv || { echo "[ssd-smart-timer] HATA: .env dotenv parser hatasi" >&2; exit 1; }
smartctl_ok() {
  command -v smartctl >/dev/null 2>&1 || [[ -x /usr/sbin/smartctl ]]
}
if ! smartctl_ok; then
  log "smartmontools kuruluyor"
  sudo DEBIAN_FRONTEND=noninteractive apt-get install -y -qq smartmontools
fi
smartctl_ok || { log "HATA: smartctl yok"; exit 1; }
# smartd daemon sabit /dev/sda 30dk SAT sorgusu atar (JMicron kopru cakismasi); yalniz haftalik timer kullanilir
sudo systemctl disable --now smartmontools.service smartd.service 2>/dev/null || true
_owner="${PI_USER:-${SUDO_USER:-${USER:-pi}}}"
[[ "$_owner" == "root" && "$REMOTE_DIR" =~ /home/([^/]+)/ ]] && _owner="${BASH_REMATCH[1]}"
for unit in pi-gateway-ssd-smart.service pi-gateway-ssd-smart.timer; do
  [[ -f "$REMOTE_DIR/host/systemd/$unit" ]] || { log "HATA: $unit yok"; exit 1; }
  _tmp="$(mktemp)"
  sed -e "s|/home/PI_USER/pi-gateway|${REMOTE_DIR}|g" \
      -e "s|/home/PI_USER|/home/${_owner}|g" \
      -e "s|User=PI_USER|User=${_owner}|g" \
      -e "s|Group=PI_USER|Group=${_owner}|g" \
      -e "s|Environment=PI_USER=PI_USER|Environment=PI_USER=${_owner}|g" \
      "$REMOTE_DIR/host/systemd/$unit" >"$_tmp"
  sudo install -o root -g root -m 644 "$_tmp" "/etc/systemd/system/$unit"
  rm -f "$_tmp"
done
sudo systemctl daemon-reload
sudo systemctl enable --now pi-gateway-ssd-smart.timer
log "Aktif: Pazar 04:30"
log "Test: REMOTE_DIR=$REMOTE_DIR bash $REMOTE_DIR/scripts/pi/check-ssd-smart.sh"
