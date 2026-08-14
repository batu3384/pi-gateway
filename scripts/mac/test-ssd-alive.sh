#!/usr/bin/env bash
# SSD alive / recovery kontrat testleri (Mac/CI — Pi gerektirmez)
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROJECT_DIR="$(cd "$SCRIPT_DIR/../.." && pwd)"
SSD_ALIVE="$PROJECT_DIR/scripts/lib/ssd-alive.sh"
HOTPLUG="$PROJECT_DIR/scripts/pi/ssd-hotplug-handler.sh"
SSD_HEALTH="$PROJECT_DIR/scripts/pi/ssd-health.sh"
SYMLINK="$PROJECT_DIR/scripts/lib/ensure-data-symlink.sh"
STACK_HEALTH="$PROJECT_DIR/scripts/lib/stack-health.sh"

die() { echo "[test-ssd-alive] HATA: $*" >&2; exit 1; }
ok() { echo "[test-ssd-alive] OK: $*"; }

[[ -f "$SSD_ALIVE" ]] || die "ssd-alive.sh yok"
source "$SSD_ALIVE"

declare -F ssd_block_present >/dev/null || die "ssd_block_present yok"
declare -F ssd_mount_healthy >/dev/null || die "ssd_mount_healthy yok"
declare -F ssd_try_remount >/dev/null || die "ssd_try_remount yok"
declare -F ssd_usb_soft_reset >/dev/null || die "ssd_usb_soft_reset yok"
declare -F ssd_under_voltage >/dev/null || die "ssd_under_voltage yok"
declare -F ssd_pci_id_ok >/dev/null || die "ssd_pci_id_ok yok"
declare -F ssd_usb_reboot_once >/dev/null || die "ssd_usb_reboot_once yok"
ok "API surface"

[[ "$SSD_PROBE_FILE" == *".pi-gateway-io-probe" ]] || die "probe dosya default yanlis: $SSD_PROBE_FILE"
[[ "$SSD_USB_AUTHORIZED_RESET" == "false" ]] || die "AUTHORIZED_RESET default false olmali"
[[ "${SSD_USB_XHCI_REBIND:-}" == "false" ]] || die "XHCI_REBIND default false olmali"
grep -q 'ssd_usb_port_disable_cycle' "$SSD_ALIVE" || die "port disable cycle yok"
grep -q 'ssd_xhci_rebind' "$SSD_ALIVE" || die "xhci rebind yok"
grep -q 'ssd_pci_id_ok' "$SSD_ALIVE" || die "pci sanitize yok"
grep -q 'ssd_sysfs_write' "$SSD_ALIVE" || die "sysfs_write yok"
ok "port disable + xhci + injection guard"

# PCI sanitize davranis
ssd_pci_id_ok "0000:01:00.0" || die "gecerli PCI reddedildi"
ssd_pci_id_ok "0000:01:00.0'; reboot #" && die "injection PCI kabul edildi"
ok "pci id sanitize"

# Rate limit: Mac'te sysfs yok — soft_reset remount-only; state yazmamali
tmp_state="$(mktemp)"
export SSD_USB_RESET_STATE_FILE="$tmp_state"
export SSD_USB_AUTHORIZED_RESET=false
export SSD_USB_XHCI_REBIND=false
export SSD_USB_PORT_DISABLE_CYCLE=true
ssd_usb_soft_reset >/dev/null 2>&1 || true
if [[ -s "$tmp_state" ]]; then
  die "Mac/sysfs yokken soft_reset rate-limit state yazdi"
fi
rm -f "$tmp_state"
ok "rate-limit Mac remount-only (sysfs yok)"

# storage_degraded auto-clear YOK
if grep -A6 '^storage_degraded()' "$STACK_HEALTH" | grep -q 'clear_storage_degraded'; then
  die "storage_degraded hâlâ auto-clear yapiyor"
fi
ok "storage_degraded no auto-clear"

# Hotplug: degraded iken early-exit yok
grep -q 'STORAGE_DEGRADED_FLAG' "$HOTPLUG" || die "hotplug degraded early-exit guard yok"
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

grep -q 'COMPOSE_MODE="core-dns"' "$PROJECT_DIR/scripts/mac/deploy.sh" \
  || die "deploy SSH fail core-dns degil"
grep -q 'core-dns' "$PROJECT_DIR/scripts/mac/deploy.sh" || die "deploy core-dns yok"
grep -q 'DEPLOY_DEGRADED=1' "$PROJECT_DIR/scripts/pi/post-deploy.sh" || die "post-deploy DEPLOY_DEGRADED recompute yok"
grep -q 'compose-profiles.sh' "$PROJECT_DIR/scripts/pi/setup-docker-ssd.sh" \
  || die "setup-docker-ssd profiles tek kaynak degil"
grep -q 'yedek atlandi' "$PROJECT_DIR/scripts/pi/restic-backup.sh" || die "restic skip yok"
if grep -q 'SD data yedegi (ephemeral)' "$PROJECT_DIR/scripts/pi/restic-backup.sh"; then
  die "restic ephemeral SD repo geri geldi"
fi
grep -q 'Smoke test (degraded' "$PROJECT_DIR/scripts/pi/smoke-test.sh" || die "smoke degraded yok"
grep -q 'adguard-ui-ufw-no-lan' "$PROJECT_DIR/scripts/pi/smoke-test.sh" || die "adguard ufw smoke yok"
ok "deploy/restic/smoke/post-deploy contracts"

[[ -f "$PROJECT_DIR/host/udev/99-pi-gateway-jmicron.rules" ]] || die "udev yok"
grep -q '152d' "$PROJECT_DIR/host/udev/99-pi-gateway-jmicron.rules" || die "udev vid yok"
ok "udev jmicron"

grep -q 'ssd-alive.sh' "$PROJECT_DIR/scripts/pi/install-privileged-scripts.sh" || die "priv ssd-alive yok"
grep -q 'world-writable' "$PROJECT_DIR/scripts/pi/install-privileged-scripts.sh" || die "priv TOCTOU guard yok"
ok "privileged install"

if ssd_mount_healthy 2>/dev/null; then
  die "Mac'te ssd_mount_healthy true dondu (beklenmez)"
fi
ok "ssd_mount_healthy Mac'te fail"

echo "[test-ssd-alive] Tum testler gecti"
