#!/usr/bin/env bash
# Boot lifecycle: Pi açıldı + kapalı süre (Telegram outbox). getUpdates yok.
set -euo pipefail
REMOTE_DIR="${REMOTE_DIR:-/home/${USER}/pi-gateway}"
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
_PG_ENV_LIB="${SCRIPT_DIR}/../lib/env-file.sh"
PG_SCRIPT_NAME="$(basename "$0")"
# shellcheck source=../lib/env-file.sh
source "${_PG_ENV_LIB:?}"
read_remote_dotenv || { echo "[${PG_SCRIPT_NAME}] HATA: .env dotenv parser hatasi" >&2; exit 1; }
# shellcheck source=../lib/notify.sh
source "${SCRIPT_DIR}/../lib/notify.sh"

log() { echo "[boot-notify] $*"; logger -t pi-gateway-boot-notify "$*" 2>/dev/null || true; }

notify_enabled || { log "Telegram yok — atlandi"; exit 0; }

notify_ensure_dir
now="$(date +%s)"
last=0
if [[ -f "$NOTIFY_LAST_ALIVE_FILE" ]]; then
  last="$(tr -d '[:space:]' <"$NOTIFY_LAST_ALIVE_FILE" 2>/dev/null || echo 0)"
fi
down=0
if [[ "$last" =~ ^[0-9]+$ ]] && (( last > 0 )) && (( now > last )); then
  down=$(( now - last ))
fi

min_down="${NOTIFY_BOOT_MIN_DOWN_SEC:-90}"
if (( last > 0 && down < min_down )); then
  log "skip downtime=${down}s < ${min_down}s"
  notify_touch_alive
  exit 0
fi

host="$(hostname -s)"
if notify_boot_up "$host" "$down"; then
  log "OK downtime=${down}s"
else
  log "WARN: telegram gonderilemedi"
fi
notify_touch_alive
exit 0
