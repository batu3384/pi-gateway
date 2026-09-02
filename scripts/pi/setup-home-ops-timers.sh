#!/usr/bin/env bash
# Faz 1 timer: kuma rapor, speedtest, deprem, modem envanteri
set -euo pipefail
REMOTE_DIR="${REMOTE_DIR:-/home/${USER}/pi-gateway}"
log() { echo "[home-ops-timers] $*"; }
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=../lib/env-file.sh
source "$SCRIPT_DIR/../lib/env-file.sh"
read_remote_dotenv || { echo "[home-ops-timers] HATA: .env dotenv parser hatasi" >&2; exit 1; }

install_unit() {
  local unit="$1"
  [[ -f "$REMOTE_DIR/host/systemd/$unit" ]] || { log "HATA: $unit yok"; return 1; }
  local tmp
  tmp="$(mktemp)"
  sed -e "s|/home/PI_USER/pi-gateway|${REMOTE_DIR}|g" \
      -e "s|/home/PI_USER|/home/${USER}|g" \
      -e "s|User=PI_USER|User=${USER}|g" \
      -e "s|Group=PI_USER|Group=${USER}|g" \
      "$REMOTE_DIR/host/systemd/$unit" >"$tmp"
  sudo install -o root -g root -m 644 "$tmp" "/etc/systemd/system/$unit"
  rm -f "$tmp"
}

for unit in \
  pi-gateway-kuma-report.service pi-gateway-kuma-report.timer \
  pi-gateway-speedtest.service pi-gateway-speedtest.timer \
  pi-gateway-quake.service pi-gateway-quake.timer \
  pi-gateway-ibb.service pi-gateway-ibb.timer \
  pi-gateway-dns-coverage.service pi-gateway-dns-coverage.timer \
  pi-gateway-dns-weekly.service pi-gateway-dns-weekly.timer \
  pi-gateway-container-watchdog.service pi-gateway-container-watchdog.timer \
  pi-gateway-crowdsec-diary.service pi-gateway-crowdsec-diary.timer
do
  install_unit "$unit"
done
if [[ "${MODEM_INVENTORY_ENABLED:-false}" == "true" ]] \
  && [[ -f /etc/pi-gateway/modem-inventory.env ]]; then
  install_unit pi-gateway-modem-inventory.service
  install_unit pi-gateway-modem-inventory.timer
fi
sudo systemctl daemon-reload
sudo systemctl enable --now \
  pi-gateway-kuma-report.timer \
  pi-gateway-speedtest.timer \
  pi-gateway-quake.timer \
  pi-gateway-ibb.timer \
  pi-gateway-dns-coverage.timer \
  pi-gateway-dns-weekly.timer \
  pi-gateway-container-watchdog.timer \
  pi-gateway-crowdsec-diary.timer
if [[ "${MODEM_INVENTORY_ENABLED:-false}" == "true" ]] \
  && [[ -f /etc/pi-gateway/modem-inventory.env ]]; then
  sudo systemctl enable --now pi-gateway-modem-inventory.timer
  sudo systemctl start pi-gateway-modem-inventory.service || \
    log "WARN: modem envanteri ilk snapshot basarisiz"
else
  sudo systemctl disable --now pi-gateway-modem-inventory.timer \
    pi-gateway-modem-inventory.service 2>/dev/null || true
fi
# OnBootSec geçmişse timer ilk scrape atlar — bir kez şimdi.
sudo systemctl start pi-gateway-ibb.service || log "WARN: ibb ilk scrape"
log "Aktif: kuma-report / speedtest / quake / ibb / dns-coverage / dns-weekly / container-watch / crowdsec-diary / modem-inventory"
