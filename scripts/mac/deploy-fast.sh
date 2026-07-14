#!/usr/bin/env bash
# Hizli deploy: docker pull atlanir (n8n imaji takilmasin)
set -euo pipefail
export DEPLOY_SKIP_PULL=true
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
exec "$SCRIPT_DIR/deploy.sh"
