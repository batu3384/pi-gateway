#!/usr/bin/env bash
# NetAlertX yeni cihaz (gizlilik MAC hariç) → Jarvis. Telegram plugin yok.
set -euo pipefail
REMOTE_DIR="${REMOTE_DIR:-/home/${USER}/pi-gateway}"
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
_PG_ENV_LIB="${SCRIPT_DIR}/../lib/env-file.sh"
# shellcheck source=../lib/env-file.sh
source "${_PG_ENV_LIB:?}"
read_remote_dotenv || exit 1
# shellcheck source=../lib/notify.sh
source "${SCRIPT_DIR}/../lib/notify.sh"

notify_enabled || exit 0

db="${NETALERTX_DB:-/mnt/ssd/pi-gateway-data/netalertx/db/app.db}"
[[ -f "$db" ]] || exit 0
state="${NETALERT_NEW_DEVICE_STATE:-/var/lib/pi-gateway/netalert-new-device.state}"
mkdir -p "$(dirname "$state")"
py="${SCRIPT_DIR}/../lib/netalert-devices.py"

if [[ ! -f "$state" ]]; then
  python3 "$py" --db "$db" --state "$state" --bootstrap >/dev/null
  exit 0
fi

payload="$(python3 "$py" --db "$db" --state "$state" --stream new_device --emit envelope)"
count="$(PAYLOAD="$payload" python3 -c 'import json,os; print(json.loads(os.environ["PAYLOAD"]).get("count") or 0)')"
[[ "$count" != "0" ]] || exit 0
plain="$(PAYLOAD="$payload" python3 -c 'import json,os; print(json.loads(os.environ["PAYLOAD"]).get("plain") or "")')"
rowid="$(PAYLOAD="$payload" python3 -c 'import json,os; print(json.loads(os.environ["PAYLOAD"]).get("max_rowid") or 0)')"
text="$(notify_escape_html "$plain")"
if NOTIFY_STRICT_RETURN=1 notify_telegram "🆕 Ağda Yeni Cihaz" "$text" "netalert-new-device" "HTML"; then
  python3 "$py" --db "$db" --state "$state" --commit-rowid "$rowid" >/dev/null
fi
