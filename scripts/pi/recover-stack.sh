#!/usr/bin/env bash
# Tek giris: stack kurtarma (health / watchdog / sd-health bunu cagirir)
# Gercek is: scripts/lib/stack-health.sh → trigger_stack_recover → recover-readonly-root
set -euo pipefail

REMOTE_DIR="${REMOTE_DIR:-/home/${USER:-pi}/pi-gateway}"
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

# shellcheck source=../lib/env-file.sh
source "$SCRIPT_DIR/../lib/env-file.sh"
_ORCH_REMOTE_DIR="$REMOTE_DIR"
load_env_file "$REMOTE_DIR/.env" || {
  logger -t "pi-gateway-recover-orch" "HATA: .env dotenv parser hatasi"
  exit 1
}
REMOTE_DIR="$_ORCH_REMOTE_DIR"
# shellcheck source=../lib/stack-health.sh
source "$SCRIPT_DIR/../lib/stack-health.sh"

LOG_TAG="pi-gateway-recover-orch"

if [[ "${STACK_AUTO_RECOVER:-true}" != "true" ]]; then
  logger -t "$LOG_TAG" "STACK_AUTO_RECOVER=false — atlandi"
  exit 1
fi

if stack_recover_suppressed && ! storage_restore_pending; then
  logger -t "$LOG_TAG" "cooldown/boot grace — atlandi"
  exit 0
fi

if trigger_stack_recover "$REMOTE_DIR"; then
  logger -t "$LOG_TAG" "OK"
  exit 0
fi

logger -t "$LOG_TAG" "FAIL"
exit 1
