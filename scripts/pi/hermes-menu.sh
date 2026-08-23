#!/usr/bin/env bash
# Minimal panel parity when Hermes owns Telegram inbox.
# Invoked by Hermes /menu skill or manually.
set -euo pipefail
REMOTE_DIR="${REMOTE_DIR:-/home/${USER}/pi-gateway}"
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
if [[ -x "$REMOTE_DIR/scripts/pi/telegram-menu.sh" ]]; then
  exec env REMOTE_DIR="$REMOTE_DIR" bash "$REMOTE_DIR/scripts/pi/telegram-menu.sh" "$@"
fi
if [[ -x "$SCRIPT_DIR/telegram-menu.sh" ]]; then
  exec env REMOTE_DIR="$REMOTE_DIR" bash "$SCRIPT_DIR/telegram-menu.sh" "$@"
fi
echo "telegram-menu.sh yok" >&2
exit 1
