#!/usr/bin/env bash
# Sabah ozeti systemd timer kurulumu
set -euo pipefail
REMOTE_DIR="${REMOTE_DIR:-/home/${USER}/pi-gateway}"
log() { echo "[morning-timer] $*"; }
notify_enabled() { [[ -n "${TELEGRAM_BOT_TOKEN:-}" && -n "${TELEGRAM_CHAT_ID:-}" ]]; }
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
_PG_ENV_LIB="${SCRIPT_DIR:-$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)}/../lib/env-file.sh"
PG_SCRIPT_NAME="$(basename "$0")"
# shellcheck source=../lib/env-file.sh
source "${_PG_ENV_LIB:?}"
read_remote_dotenv || { echo "[${PG_SCRIPT_NAME:-script}] HATA: .env dotenv parser hatasi" >&2; exit 1; }
# Hermes 07:00 panosu varken 08:00 systemd özeti çift sabah spam
# (gateway henüz up olmasa da enabled/.env/jobs.json yeterli)
_jobs="${HERMES_HOME:-$HOME/.hermes}/cron/jobs.json"
if [[ "${HERMES_TELEGRAM_GATEWAY:-}" == "true" ]] \
  || systemctl is-active --quiet hermes-gateway 2>/dev/null \
  || systemctl is-enabled --quiet hermes-gateway 2>/dev/null \
  || { [[ -f "$_jobs" ]] && grep -qE 'Günaydın Panosu \(07:00\)|"expr": "0 7 \* \* \*"' "$_jobs"; }; then
  sudo systemctl disable --now pi-gateway-morning.timer 2>/dev/null || true
  log "Hermes 07:00 panosu aktif — 08:00 systemd timer kapali"
  exit 0
fi
for unit in pi-gateway-morning.service pi-gateway-morning.timer; do
  [[ -f "$REMOTE_DIR/host/systemd/$unit" ]] || { log "HATA: $unit yok"; exit 1; }
  sudo cp "$REMOTE_DIR/host/systemd/$unit" "/etc/systemd/system/$unit"
  sudo sed -i "s|PI_USER|${USER}|g" "/etc/systemd/system/$unit" 2>/dev/null || \
    sudo sed -i '' "s|PI_USER|${USER}|g" "/etc/systemd/system/$unit" 2>/dev/null || true
done
sudo systemctl daemon-reload
sudo systemctl enable --now pi-gateway-morning.timer
log "Aktif: her gun 08:00 (Europe/Istanbul sistem saati)"
log "Test: REMOTE_DIR=$REMOTE_DIR bash $REMOTE_DIR/scripts/pi/morning-summary.sh"
