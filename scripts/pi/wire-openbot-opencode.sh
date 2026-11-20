#!/usr/bin/env bash
# Eski Docker ocbin wrapper yerine OpenBot provider-runtimes (checksum doğrulanmış).
set -euo pipefail
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
exec bash "${SCRIPT_DIR}/repair-openbot-provider-runtimes.sh"