#!/usr/bin/env bash
# SSD chaos drill + FSM runbook contracts
set -euo pipefail
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
die() { echo "[test-ssd-chaos] HATA: $*" >&2; exit 1; }

[[ -x "$ROOT/scripts/pi/chaos-storage-drill.sh" ]] || die "chaos-storage-drill.sh yok"
[[ -f "$ROOT/docs/runbooks/SSD-FSM.md" ]] || die "SSD-FSM runbook yok"
grep -q 'CHAOS_DRY_RUN' "$ROOT/scripts/pi/chaos-storage-drill.sh" || die "dry-run modu yok"
grep -q 'CHAOS_CONFIRM' "$ROOT/scripts/pi/chaos-storage-drill.sh" || die "confirm gate yok"
CHAOS_DRY_RUN=true REMOTE_DIR="$ROOT" bash "$ROOT/scripts/pi/chaos-storage-drill.sh" || die "dry-run drill fail"
echo "[test-ssd-chaos] OK"
