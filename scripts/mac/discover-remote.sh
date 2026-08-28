#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=../lib/common.sh
source "$SCRIPT_DIR/../lib/common.sh"
load_env

PI_USER="${PI_USER:-pi}"
PI_HOST="${PI_HOST:-}"

[[ -n "$PI_HOST" ]] || die "PI_HOST empty. Pi acik olunca calistir."

log "Discovering network on $PI_USER@$PI_HOST ..."
DISCOVERY="$(ssh -o ConnectTimeout=10 "$PI_USER@$PI_HOST" 'bash -s' < "$SCRIPT_DIR/../pi/discover-network.sh")"
echo "$DISCOVERY"

ENV_FILE="$PROJECT_DIR/.env"
touch "$ENV_FILE"

while IFS='=' read -r key value; do
  [[ -z "$key" ]] && continue
  if grep -q "^${key}=" "$ENV_FILE"; then
    sed -i.bak "s|^${key}=.*|${key}=${value}|" "$ENV_FILE"
  else
    echo "${key}=${value}" >> "$ENV_FILE"
  fi
done <<< "$DISCOVERY"

rm -f "$ENV_FILE.bak"
discovered_ip="$(awk -F= '$1 == "PI_STATIC_IP" {print substr($0, index($0, "=") + 1); exit}' "$ENV_FILE")"
log "Updated .env with discovered network (static IP candidate: ${discovered_ip:-unknown})"
