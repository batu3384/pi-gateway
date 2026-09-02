#!/usr/bin/env bash
# CrowdSec gece defteri — aktif ban ozeti + arsiv (kural tabanli, LLM yok).
set -euo pipefail
REMOTE_DIR="${REMOTE_DIR:-/home/${USER}/pi-gateway}"
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
FORMAT_PY="${SCRIPT_DIR}/../lib/crowdsec-diary-format.py"
# shellcheck source=../lib/env-file.sh
source "$SCRIPT_DIR/../lib/env-file.sh"
read_remote_dotenv || { echo "[crowdsec-diary] HATA: .env" >&2; exit 1; }
load_telegram_from_hermes || true
# shellcheck source=../lib/notify.sh
source "$SCRIPT_DIR/../lib/notify.sh"
ARCHIVE="$SCRIPT_DIR/../lib/archive-bulletin.sh"

log() { echo "[crowdsec-diary] $*"; }

if [[ "${1:-}" == "--self-check" ]]; then
  [[ -f "$FORMAT_PY" ]] || exit 1
  printf '[{"value":"203.0.113.1","scenario":"test/http-scan"}]' \
    | python3 "$FORMAT_PY" | grep -q 'Gece Saldırı' || exit 1
  log "self-check OK"
  exit 0
fi

docker ps --format '{{.Names}}' | grep -qx crowdsec || exit 0

body="$(docker exec crowdsec cscli decisions list -o json 2>/dev/null | python3 "$FORMAT_PY")"
[[ -n "${body// }" ]] || { log "ban yok — atlandi"; exit 0; }

body | bash "$ARCHIVE" crowdsec-diary >/dev/null
notify_enabled || exit 0
notify_crowdsec_diary "$body" || true
log "Tamamlandi (${#body} byte)"
