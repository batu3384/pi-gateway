#!/usr/bin/env bash
# Deprem P1 — AFAD; Telegram yalnız eşik+filtre sonrası
set -euo pipefail
REMOTE_DIR="${REMOTE_DIR:-/home/${USER}/pi-gateway}"
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PY="${SCRIPT_DIR}/../lib/quake-alert.py"
_PG_ENV_LIB="${SCRIPT_DIR}/../lib/env-file.sh"
PG_SCRIPT_NAME="$(basename "$0")"
# shellcheck source=../lib/env-file.sh
source "${_PG_ENV_LIB:?}"
read_remote_dotenv || { echo "[${PG_SCRIPT_NAME}] HATA: .env dotenv parser hatasi" >&2; exit 1; }
load_telegram_from_hermes || true
# shellcheck source=../lib/notify.sh
source "$SCRIPT_DIR/../lib/notify.sh"

if [[ "${1:-}" == "--self-check" ]]; then
  python3 "$PY" --self-check
  exit 0
fi

notify_enabled || exit 0
export QUAKE_STATE="${QUAKE_STATE:-/var/lib/pi-gateway/quake-state.json}"
out="$(python3 "$PY" 2>/dev/null || true)"
[[ -n "${out// }" ]] || exit 0
n=0
while IFS= read -r block; do
  [[ -n "${block// }" ]] || continue
  n=$((n + 1))
  notify_send_message "$(printf '⚠️ Pi Gateway · Deprem\n\n%s' "$block")" || true
done < <(printf '%s\n' "$out" | awk 'BEGIN{RS="---\n"} {gsub(/^[ \t\n]+|[ \t\n]+$/,""); if(length($0)) print}')
exit 0
