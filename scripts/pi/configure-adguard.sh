#!/usr/bin/env bash
# AdGuard DNS kritik yol: bekle -> upstream/PTR -> filtreler (+ rewrite)
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REMOTE_DIR="${REMOTE_DIR:-/home/${USER}/pi-gateway}"

export REMOTE_DIR
bash "$SCRIPT_DIR/wait-adguard-dns.sh"
bash "$SCRIPT_DIR/apply-adguard-dns.sh"
bash "$SCRIPT_DIR/apply-adguard-filters.sh"
bash "$SCRIPT_DIR/apply-adguard-rewrites.sh"
