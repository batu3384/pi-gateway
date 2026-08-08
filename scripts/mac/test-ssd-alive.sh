#!/usr/bin/env bash
# SSD alive / recovery kontrat testleri (Mac/CI — Pi gerektirmez)
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROJECT_DIR="$(cd "$SCRIPT_DIR/../.." && pwd)"
SSD_ALIVE="$PROJECT_DIR/scripts/lib/ssd-alive.sh"
HOTPLUG="$PROJECT_DIR/scripts/pi/ssd-hotplug-handler.sh"
SSD_HEALTH="$PROJECT_DIR/scripts/pi/ssd-health.sh"
SYMLINK="$PROJECT_DIR/scripts/lib/ensure-data-symlink.sh"

die() { echo "[test-ssd-alive] HATA: $*" >&2; exit 1; }
ok() { echo "[test-ssd-alive] OK: $*"; }

[[ -f "$SSD_ALIVE" ]] || die "ssd-alive.sh yok"
# shellcheck source=/dev/null
source "$SSD_ALIVE"

# --- API surface ---
declare -F ssd_block_present >/dev/null || die "ssd_block_present yok"
declare -F ssd_mount_healthy >/dev/null || die "ssd_mount_healthy yok"
declare -F ssd_try_remount >/dev/null || die "ssd_try_remount yok"
declare -F ssd_usb_soft_reset >/dev/null || die "ssd_usb_soft_reset yok"
declare -F ssd_under_voltage >/dev/null || die "ssd_under_voltage yok"
ok "API surface"

# --- Probe defaults ---
[[ "$SSD_PROBE_FILE" == *".pi-gateway-io-probe" ]] || die "probe dosya default yanlis: $SSD_PROBE_FILE"
[[ "$SSD_USB_AUTHORIZED_RESET" == "false" ]] || die "AUTHORIZED_RESET default false olmali"
ok "guvenli defaults (authorized off, io-probe)"

# --- Rate limit: remount soft-reset authorized kapali iken state dosyasi yazmamali ---
tmp_state="$(mktemp)"
export SSD_USB_RESET_STATE_FILE="$tmp_state"
SSD_USB_AUTHORIZED_RESET=false
# Mac'te mount yok — soft_reset remount fail eder ama rate file bos kalmali
ssd_usb_soft_reset >/dev/null 2>&1 || true
if [[ -s "$tmp_state" ]]; then
  die "authorized=false iken rate-limit state yazildi (remount budget yakma)"
fi
rm -f "$tmp_state"
ok "rate-limit sadece authorized cycle"

# --- Hotplug / health contracts ---
grep -q 'SSD_HOTPLUG_REENTRY' "$HOTPLUG" || die "hotplug reentry korumasi yok"
grep -q 'umount -l' "$HOTPLUG" || die "hotplug stale umount yok"
grep -q 'ssd_ready_for_symlink\|ssd_mount_healthy' "$SYMLINK" || die "symlink stale-mount korumasi yok"
grep -q 'ssd_under_voltage' "$SSD_HEALTH" || die "ssd-health undervolt helper kullanmiyor"
grep -q 'PathExistsGone' "$PROJECT_DIR/host/systemd/pi-ssd-watch.path" || die "PathExistsGone yok"
if grep -q 'ConditionPathExists=/dev/disk/by-label/pi-data' \
  "$PROJECT_DIR/host/systemd/pi-ssd-watch.service"; then
  die "ConditionPathExists hâlâ var"
fi
ok "hotplug+symlink+path unit"

# --- Deploy / restic / smoke ---
grep -q 'core-dns' "$PROJECT_DIR/scripts/mac/deploy.sh" || die "deploy core-dns yok"
grep -q 'yedek atlandi' "$PROJECT_DIR/scripts/pi/restic-backup.sh" || die "restic skip yok"
if grep -q 'SD data yedegi (ephemeral)' "$PROJECT_DIR/scripts/pi/restic-backup.sh"; then
  die "restic ephemeral SD repo geri geldi"
fi
grep -q 'Smoke test (degraded' "$PROJECT_DIR/scripts/pi/smoke-test.sh" || die "smoke degraded yok"
ok "deploy/restic/smoke contracts"

# --- udev ---
[[ -f "$PROJECT_DIR/host/udev/99-pi-gateway-jmicron.rules" ]] || die "udev yok"
grep -q '152d' "$PROJECT_DIR/host/udev/99-pi-gateway-jmicron.rules" || die "udev vid yok"
ok "udev jmicron"

# --- Privileged install list ---
grep -q 'ssd-alive.sh' "$PROJECT_DIR/scripts/pi/install-privileged-scripts.sh" || die "priv ssd-alive yok"
grep -q 'ssd-health.sh' "$PROJECT_DIR/scripts/pi/install-privileged-scripts.sh" || die "priv ssd-health yok"
ok "privileged install"

# --- Mac'te mount yok: ssd_mount_healthy fail ---
if ssd_mount_healthy 2>/dev/null; then
  die "Mac'te ssd_mount_healthy true dondu (beklenmez)"
fi
ok "ssd_mount_healthy Mac'te fail"

echo "[test-ssd-alive] Tum testler gecti"
