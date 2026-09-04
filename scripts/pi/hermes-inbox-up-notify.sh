#!/usr/bin/env bash
# Asistan sohbeti geri — kapanış mesajının çifti (Pi reboot = boot-notify).
# Pi reboot "Açıldı" = boot-notify.sh — bu script yalniz hermes-gateway restart.
set -euo pipefail
REMOTE_DIR="${REMOTE_DIR:-/home/${USER}/pi-gateway}"
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# privileged copy: SCRIPT_DIR under /usr/local/lib — dotenv from REMOTE_DIR
_PG_ENV_LIB="${REMOTE_DIR}/scripts/lib/env-file.sh"
if [[ ! -f "$_PG_ENV_LIB" ]]; then
  _PG_ENV_LIB="${SCRIPT_DIR}/../lib/env-file.sh"
fi
PG_SCRIPT_NAME="$(basename "$0")"
# shellcheck source=../lib/env-file.sh
source "${_PG_ENV_LIB:?}"
read_remote_dotenv || { echo "[${PG_SCRIPT_NAME}] HATA: .env dotenv parser hatasi" >&2; exit 1; }
# shellcheck source=../lib/notify.sh
source "${REMOTE_DIR}/scripts/lib/notify.sh" 2>/dev/null \
  || source "${SCRIPT_DIR}/../lib/notify.sh"

log() { echo "[hermes-up] $*"; logger -t pi-gateway-hermes-up "$*" 2>/dev/null || true; }

notify_enabled || { log "Telegram yok — atlandi"; exit 0; }
notify_ensure_dir

# Crash-loop spam: RestartSec=5 ile her 5s Telegram olmasin
cooldown="${NOTIFY_HERMES_UP_COOLDOWN_SEC:-120}"
stamp="${NOTIFY_STATE_DIR}/hermes-inbox"
now="$(date +%s)"
if [[ -f "$stamp" ]]; then
  last="$(tr -d '[:space:]' <"$stamp" 2>/dev/null || echo 0)"
  if [[ "$last" =~ ^[0-9]+$ ]] && (( now - last < cooldown )); then
    log "skip cooldown ${cooldown}s (last=$((now - last))s ago)"
    exit 0
  fi
fi

unit=hermes-gateway.service
wait_secs="${HERMES_UP_NOTIFY_WAIT_SEC:-45}"
connected=0
# ExecStartPost: process yeni dogmus olabilir (activating). inactive ile hemen cikma.
for _ in $(seq 1 "$wait_secs"); do
  if journalctl -u "$unit" --since "2 min ago" -n 200 --no-pager 2>/dev/null \
    | grep -qE 'Connected to Telegram|polling_started=True'; then
    connected=1
    break
  fi
  sleep 1
done
if [[ "$connected" -ne 1 ]]; then
  log "WARN: Connected yok ${wait_secs}s — mesaj yok"
  exit 0
fi

host="$(hostname -s)"
if notify_hermes_inbox_up "$host"; then
  log "OK inbox up notify"
else
  log "WARN: telegram gonderilemedi"
fi
exit 0
