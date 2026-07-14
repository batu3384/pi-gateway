#!/usr/bin/env bash
set -euo pipefail
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REMOTE_DIR="${REMOTE_DIR:-/home/${USER}/pi-gateway}"
export REMOTE_DIR
exec bash "${SCRIPT_DIR}/../lib/ensure-data-symlink.sh" "${1:-repair}"
