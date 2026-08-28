#!/usr/bin/env bash
# ZTE H3600P cihaz snapshot'i — yalnızca read-only modem endpoint'leri.
set -euo pipefail

REMOTE_DIR="${REMOTE_DIR:-/home/${USER}/pi-gateway}"
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ENV_LIB="${SCRIPT_DIR}/../lib/env-file.sh"
# shellcheck source=../lib/env-file.sh
source "$ENV_LIB"
read_remote_dotenv || {
  echo "[sync-modem-inventory] HATA: .env dotenv parser hatasi" >&2
  exit 1
}

# Credential source is intentionally outside repository/.env.
if [[ -n "${CREDENTIALS_DIRECTORY:-}" && -r "${CREDENTIALS_DIRECTORY}/modem" ]]; then
  load_env_file "${CREDENTIALS_DIRECTORY}/modem" || {
    echo "[sync-modem-inventory] HATA: systemd credential parser hatasi" >&2
    exit 1
  }
elif [[ -n "${MODEM_CREDENTIAL_FILE:-}" && -r "$MODEM_CREDENTIAL_FILE" ]]; then
  load_env_file "$MODEM_CREDENTIAL_FILE" || {
    echo "[sync-modem-inventory] HATA: modem credential parser hatasi" >&2
    exit 1
  }
fi

if [[ "${MODEM_INVENTORY_ENABLED:-false}" != "true" ]]; then
  echo "[sync-modem-inventory] atlandi: MODEM_INVENTORY_ENABLED=true degil"
  exit 0
fi

: "${MODEM_URL:=http://192.168.1.1}"
: "${MODEM_INVENTORY_PATH:=${REMOTE_DIR}/data/modem-inventory.json}"
: "${MODEM_USERNAME:?MODEM_USERNAME credential eksik}"
: "${MODEM_PASSWORD:?MODEM_PASSWORD credential eksik}"
export MODEM_URL MODEM_INVENTORY_PATH MODEM_USERNAME MODEM_PASSWORD
export MODEM_HTTP_TIMEOUT_SEC="${MODEM_HTTP_TIMEOUT_SEC:-8}"

exec python3 "${SCRIPT_DIR}/../lib/zte-h3600p.py" \
  --url "$MODEM_URL" \
  --output "$MODEM_INVENTORY_PATH"
