#!/usr/bin/env bash
# recover-readonly-root icinden batu kullanicisi ile docker compose up
set -euo pipefail

REMOTE_DIR="${REMOTE_DIR:-/home/${USER}/pi-gateway}"
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=/dev/null
[[ -f "$REMOTE_DIR/.env" ]] && source "$REMOTE_DIR/.env"
# shellcheck source=../lib/compose-profiles.sh
source "$SCRIPT_DIR/../lib/compose-profiles.sh"

cd "$REMOTE_DIR/compose"
mapfile -t profiles < <(compose_profiles)
exec docker compose --env-file ../.env "${profiles[@]}" up -d
