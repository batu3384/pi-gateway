#!/usr/bin/env bash
# Hizli kod sync: DEPLOY_MODE=code (bootstrap/canary/full post-deploy yok).
# Compose/image/UFW degisikligi icin: make deploy
set -euo pipefail
export DEPLOY_MODE=code
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
exec "$SCRIPT_DIR/deploy.sh"
