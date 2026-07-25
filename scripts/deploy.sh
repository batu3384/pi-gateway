#!/usr/bin/env bash
# Compatibility wrapper — canonical deploy is scripts/mac/deploy.sh
set -euo pipefail
exec "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/mac/deploy.sh" "$@"
