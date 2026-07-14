#!/usr/bin/env bash
set -euo pipefail

REMOTE_DIR="${REMOTE_DIR:-/home/${USER}/pi-gateway}"
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=/dev/null
[[ -f "$REMOTE_DIR/.env" ]] && source "$REMOTE_DIR/.env"
# shellcheck source=../lib/notify.sh
source "$SCRIPT_DIR/../lib/notify.sh"

notify_health_systemd_fail "$(hostname -s 2>/dev/null || echo pi-gateway)"
