#!/usr/bin/env bash
# Tek giris: stack kurtarma (health / watchdog / sd-health bunu cagirir)
# Gercek is: scripts/lib/stack-health.sh → trigger_stack_recover → recover-readonly-root
set -euo pipefail

REMOTE_DIR="${REMOTE_DIR:-/home/${USER:-pi}/pi-gateway}"
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

# shellcheck source=/dev/null
[[ -f "$REMOTE_DIR/.env" ]] && set -a && source "$REMOTE_DIR/.env" && set +a
# shellcheck source=../lib/stack-health.sh
source "$SCRIPT_DIR/../lib/stack-health.sh"

LOG_TAG="pi-gateway-recover-orch"

if [[ "${STACK_AUTO_RECOVER:-true}" != "true" ]]; then
  logger -t "$LOG_TAG" "STACK_AUTO_RECOVER=false — atlandi"
  exit 1
fi

if stack_recover_suppressed; then
  logger -t "$LOG_TAG" "cooldown/boot grace — atlandi"
  exit 0
fi

if trigger_stack_recover "$REMOTE_DIR"; then
  logger -t "$LOG_TAG" "OK"
  exit 0
fi

logger -t "$LOG_TAG" "FAIL"
exit 1
