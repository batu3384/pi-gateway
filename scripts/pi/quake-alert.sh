#!/usr/bin/env bash
# Deprem Telegram — AFAD+Kandilli HTTP poll → notify.sh (Bot API outbox).
# Hermes/ajan YOK. EEW/saniye YOK. Gecikme ≈ yayın + poll (10s).
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
LOCK="${QUAKE_LOCK:-/var/lib/pi-gateway/quake.lock}"
mkdir -p "$(dirname "$LOCK")" "$(dirname "$QUAKE_STATE")"
# Önceki poll bitmeden yenisi → çift Telegram / state yarışı yok
exec 9>"$LOCK"
flock -n 9 || exit 0
# stderr journal'a kalsın (AFAD 500 vb.); stdout yalnız mesaj blokları
out="$(python3 "$PY" 2> >(logger -t pi-gateway-quake -p user.warning) || true)"
[[ -n "${out// }" ]] || exit 0
while IFS= read -r block; do
  [[ -n "${block// }" ]] || continue
  notify_send_message "$(printf '⚠️ Pi Gateway · Deprem\n\n%s' "$block")" || true
done < <(printf '%s\n' "$out" | awk 'BEGIN{RS="---\n"} {gsub(/^[ \t\n]+|[ \t\n]+$/,""); if(length($0)) print}')
exit 0
