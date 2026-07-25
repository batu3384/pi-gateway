#!/usr/bin/env bash
# Kurtarma kontrat testleri (Mac/CI — docker gerektirmez)
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROJECT_DIR="$(cd "$SCRIPT_DIR/../.." && pwd)"
STACK_HEALTH="$PROJECT_DIR/scripts/lib/stack-health.sh"

die() { echo "[validate-recovery] HATA: $*" >&2; exit 1; }
ok() { echo "[validate-recovery] OK: $*"; }

[[ -f "$STACK_HEALTH" ]] || die "stack-health.sh yok"

# shellcheck source=/dev/null
source "$STACK_HEALTH"

if root_rw_ok 2>/dev/null; then
  : # Mac'te genelde rw
else
  die "root_rw_ok beklenmedik sekilde false (rw ortam)"
fi
ok "root_rw_ok calisiyor"

if stack_core_ok 2>/dev/null; then
  die "stack_core_ok docker yokken 0 dondu"
fi
ok "stack_core_ok docker yokken fail"

export STORAGE_DEGRADED_FLAG="/tmp/pi-gateway-test-storage-degraded"
rm -f "$STORAGE_DEGRADED_FLAG"
touch "$STORAGE_DEGRADED_FLAG"
if storage_degraded; then
  ok "storage_degraded flag okunuyor"
else
  die "storage_degraded flag algilanmadi"
fi
rm -f "$STORAGE_DEGRADED_FLAG"

lock_dir="$(dirname "$STACK_LOCK_FILE")"
[[ "$lock_dir" == "/run/pi-gateway" ]] || die "STACK_LOCK_FILE tmpfs degil: $STACK_LOCK_FILE"
ok "lock tmpfs path: $STACK_LOCK_FILE"

tmp_lock="/tmp/pi-gateway-lock-test-$$"
mkdir -p "$(dirname "$tmp_lock")"
touch "$tmp_lock" && echo test >"$tmp_lock" || die "lock dosyasi yazilamadi"
rm -f "$tmp_lock"
ok "lock dosyasi yazilabilirligi (simule)"

grep -q 'stack_fully_healthy && root_rw_ok' "$PROJECT_DIR/scripts/pi/recover-readonly-root.sh" \
  || die "recover early exit root_rw_ok kontrolu yok"
ok "recover early exit root_rw_ok"

line_rw="$(grep -n 'ensure_root_rw' "$PROJECT_DIR/scripts/pi/recover-readonly-root.sh" | head -1 | cut -d: -f1)"
line_lock="$(grep -n 'acquire_recover_lock_wait' "$PROJECT_DIR/scripts/pi/recover-readonly-root.sh" | head -1 | cut -d: -f1)"
[[ -n "$line_rw" && -n "$line_lock" && "$line_rw" -lt "$line_lock" ]] \
  || die "remount lock'tan once degil (rw=$line_rw lock=$line_lock)"
ok "remount lock'tan once"

# dns_degraded + COMPOSE forward + clobber marker
dns_degraded_on_ssd_loss >/dev/null 2>&1 || true
if DNS_DEGRADED_ON_SSD_LOSS=false STORAGE_FALLBACK_SD=false dns_degraded_on_ssd_loss; then
  die "dns_degraded_on_ssd_loss her iki flag false iken true dondu"
fi
ok "dns_degraded fail-closed"

DNS_DEGRADED_ON_SSD_LOSS=true STORAGE_FALLBACK_SD=false dns_degraded_on_ssd_loss \
  || die "DNS_DEGRADED_ON_SSD_LOSS=true iken false"
ok "dns_degraded default path"

grep -q 'COMPOSE_RECOVER_MODE=' "$STACK_HEALTH" || die "COMPOSE_RECOVER_MODE forward yok"
ok "COMPOSE_RECOVER_MODE forward"

SYMLINK="$PROJECT_DIR/scripts/lib/ensure-data-symlink.sh"
grep -q 'pi-gateway-sd-degraded-ephemeral' "$SYMLINK" || die "ephemeral marker yok"
grep -q 'clobber' "$SYMLINK" || die "clobber korumasi yorumu yok"
ok "symlink clobber korumasi"

echo "[validate-recovery] Tum kontrat testleri gecti"
