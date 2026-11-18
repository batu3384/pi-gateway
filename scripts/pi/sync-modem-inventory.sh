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

: "${MODEM_URL:=https://192.168.1.1}"
: "${MODEM_INVENTORY_PATH:=${REMOTE_DIR}/data/modem-inventory.json}"
: "${MODEM_USERNAME:?MODEM_USERNAME credential eksik}"
: "${MODEM_PASSWORD:?MODEM_PASSWORD credential eksik}"
MODEM_ALLOW_HTTP="${MODEM_ALLOW_HTTP:-false}"
MODEM_TLS_CA_FILE="${MODEM_TLS_CA_FILE:-}"
MODEM_TLS_INSECURE="${MODEM_TLS_INSECURE:-false}"
export MODEM_URL MODEM_INVENTORY_PATH MODEM_USERNAME MODEM_PASSWORD
export MODEM_ALLOW_HTTP MODEM_TLS_CA_FILE MODEM_TLS_INSECURE
export MODEM_HTTP_TIMEOUT_SEC="${MODEM_HTTP_TIMEOUT_SEC:-8}"

python3 "${SCRIPT_DIR}/../lib/zte-h3600p.py" \
  --url "$MODEM_URL" \
  --output "$MODEM_INVENTORY_PATH"

if [[ -f "${SCRIPT_DIR}/../lib/sync-adguard-clients.py" ]]; then
  AGH_ADMIN_USER="${AGH_ADMIN_USER:-admin}" \
    AGH_ADMIN_PASSWORD="${AGH_ADMIN_PASSWORD:-}" \
    ADGUARD_WEB_PORT="${ADGUARD_WEB_PORT:-8080}" \
    PI_STATIC_IP="${PI_STATIC_IP:-}" \
    PI_IPV6_ULA="${PI_IPV6_ULA:-}" \
    PI_INTERFACE="${PI_INTERFACE:-eth0}" \
    ADGUARD_CLIENT_ALIASES_PATH="${ADGUARD_CLIENT_ALIASES_PATH:-/var/lib/pi-gateway/client-aliases.json}" \
    MODEM_INVENTORY_PATH="$MODEM_INVENTORY_PATH" \
    python3 "${SCRIPT_DIR}/../lib/sync-adguard-clients.py" || true
fi
