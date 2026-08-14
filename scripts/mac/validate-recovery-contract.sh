#!/usr/bin/env bash
# Kurtarma kontrat testleri (Mac/CI — docker gerektirmez)
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROJECT_DIR="$(cd "$SCRIPT_DIR/../.." && pwd)"
STACK_HEALTH="$PROJECT_DIR/scripts/lib/stack-health.sh"

die() { echo "[validate-recovery] HATA: $*" >&2; exit 1; }
ok() { echo "[validate-recovery] OK: $*"; }

[[ -f "$STACK_HEALTH" ]] || die "stack-health.sh yok"

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
# Auto-clear olmamali: flag dosyasi varken true kalir (symlink/mount ne olursa olsun)
if grep -A12 '^storage_degraded()' "$STACK_HEALTH" | grep -q 'clear_storage_degraded'; then
  die "storage_degraded auto-clear geri geldi"
fi
ok "storage_degraded no auto-clear"
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

SSD_ALIVE="$PROJECT_DIR/scripts/lib/ssd-alive.sh"
[[ -f "$SSD_ALIVE" ]] || die "ssd-alive.sh yok"
grep -q 'ssd_mount_healthy' "$SSD_ALIVE" || die "ssd_mount_healthy yok"
grep -q 'ssd_usb_soft_reset' "$SSD_ALIVE" || die "ssd_usb_soft_reset yok"
ok "ssd-alive API"

grep -q 'ssd-alive.sh' "$STACK_HEALTH" || die "stack-health ssd-alive source yok"
grep -q 'ssd_mount_healthy' "$STACK_HEALTH" || die "stack-health ssd_mount_healthy kullanmiyor"
ok "stack-health ssd-alive entegrasyonu"

grep -q 'PathExistsGone' "$PROJECT_DIR/host/systemd/pi-ssd-watch.path" \
  || die "pi-ssd-watch.path PathExistsGone yok"
if grep -q 'ConditionPathExists=/dev/disk/by-label/pi-data' \
  "$PROJECT_DIR/host/systemd/pi-ssd-watch.service"; then
  die "pi-ssd-watch.service ConditionPathExists hâlâ var (disconnect olu)"
fi
ok "ssd-watch disconnect path"

grep -q 'ssd_mount_healthy\|Stale' "$PROJECT_DIR/scripts/pi/ssd-hotplug-handler.sh" \
  || die "hotplug stale/healthy yok"
ok "hotplug stale+remount"

[[ -f "$PROJECT_DIR/scripts/pi/ssd-health.sh" ]] || die "ssd-health.sh yok"
grep -q 'ssd-health.sh' "$PROJECT_DIR/scripts/pi/check-sd-health.sh" \
  || die "check-sd-health ssd-health cagirmiyor"
ok "ssd-health zinciri"

grep -q 'core-dns' "$PROJECT_DIR/scripts/mac/deploy.sh" \
  || die "deploy core-dns branch yok"
ok "deploy core-dns"

grep -q 'yedek atlandi' "$PROJECT_DIR/scripts/pi/restic-backup.sh" \
  || die "restic degraded skip yok"
grep -q 'RESTIC_TIMEOUT_SEC' "$PROJECT_DIR/scripts/pi/restic-backup.sh" \
  || die "restic timeout yok"
if grep -q 'SD data yedegi (ephemeral)' "$PROJECT_DIR/scripts/pi/restic-backup.sh"; then
  die "restic hâlâ ephemeral SD repo yaziyor"
fi
ok "restic degraded skip + timeout"

grep -q 'ufw-ssh-lan' "$PROJECT_DIR/scripts/pi/smoke-test.sh" \
  || die "smoke ufw-ssh-lan yok"
grep -q 'Smoke test (degraded' "$PROJECT_DIR/scripts/pi/smoke-test.sh" \
  || die "smoke degraded early exit yok"
ok "smoke degraded"

[[ -f "$PROJECT_DIR/host/udev/99-pi-gateway-jmicron.rules" ]] \
  || die "udev jmicron rules yok"
ok "udev jmicron"

# Deep SSD alive regression (Mac)
if [[ -x "$PROJECT_DIR/scripts/mac/test-ssd-alive.sh" ]] \
  || [[ -f "$PROJECT_DIR/scripts/mac/test-ssd-alive.sh" ]]; then
  bash "$PROJECT_DIR/scripts/mac/test-ssd-alive.sh" || die "test-ssd-alive basarisiz"
  ok "test-ssd-alive"
fi

grep -q 'ssd_ready_for_symlink\|ssd_mount_healthy' "$PROJECT_DIR/scripts/lib/ensure-data-symlink.sh" \
  || die "ensure-data-symlink stale mount korumasi yok"
ok "symlink stale-mount korumasi"

echo "[validate-recovery] Tum kontrat testleri gecti"
