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
# shellcheck source=../lib/ssd-alive.sh
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
[[ "${SSD_USB_CYCLE_ON_HANG:-}" == "true" ]] || die "CYCLE_ON_HANG default true olmali"
[[ "${SSD_USB_PORT_SCAN_MAX:-}" == "1" ]] || die "PORT_SCAN_MAX default 1 olmali"
grep -q 'ssd_usb_port_candidates' "$SSD_ALIVE" || die "port aday tarama yok"
grep -q 'ssd_usb_remember_port' "$SSD_ALIVE" || die "port hatirla yok"
grep -q 'ssd_usb_disable_lpm' "$SSD_ALIVE" || die "LPM disable yok"
grep -q 'ssd_usb_reset_record_once' "$SSD_ALIVE" || die "rate-limit session yok"
grep -q 'ssd_usb_port_cycle_one' "$SSD_ALIVE" || die "tek port cycle yok"
grep -q 'ssd_usb_storage_rebind' "$SSD_ALIVE" || die "usb-storage rebind yok"
grep -q 'SSD_USB_CYCLE_ON_HANG' "$SSD_ALIVE" || die "CYCLE_ON_HANG yok"
grep -q 'usbcore.quirks=' "$SSD_ALIVE" || die "usbcore NO_LPM quirk kontrol yok"
grep -q 'os.fsync' "$SSD_ALIVE" || die "probe fsync yok"
if awk '/^ssd_usb_port_disable_cycle\(\)/,/^ssd_xhci_rebind\(\)/' "$SSD_ALIVE" \
  | grep -q 'for port_sys in "${ports[@]}"; do'; then
  die "port cycle hâlâ tum portlari ayni anda kesiyor"
fi
ok "port disable + merdiven + injection guard"

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

# mkdir lock: ikinci cagri fail
_lock_tmp="$(mktemp -d)"
export SSD_USB_RESET_LOCK_DIR="$_lock_tmp/held"
mkdir "$SSD_USB_RESET_LOCK_DIR"
if ssd_usb_soft_reset >/dev/null 2>&1; then
  die "lock varken soft_reset gecti"
fi
rmdir "$SSD_USB_RESET_LOCK_DIR"
unset SSD_USB_RESET_LOCK_DIR
rmdir "$_lock_tmp"
ok "soft-reset mkdir lock"

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
if awk '/ssd_under_voltage/,/if storage_degraded/' "$SSD_HEALTH" | grep -q ssd_usb_disable_autosuspend; then
  die "ssd-health saglikli poll USB sysfs poke"
fi
grep -q 'PathExistsGone' "$PROJECT_DIR/host/systemd/pi-ssd-watch.path" || die "PathExistsGone yok"
if grep -q 'ConditionPathExists=/dev/disk/by-label/pi-data' \
  "$PROJECT_DIR/host/systemd/pi-ssd-watch.service"; then
  die "ConditionPathExists hâlâ var"
fi
ok "hotplug+symlink+path unit"

grep -q 'SSH compose mode probe failed' "$PROJECT_DIR/scripts/mac/deploy.sh" \
  || die "deploy SSH fail-closed yok"
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
grep -q 'SYSTEMD_WANTS' "$PROJECT_DIR/host/udev/99-pi-gateway-jmicron.rules" \
  || die "udev hotplug systemd wants yok"
if grep -q 'ACTION=="add|remove|change", SUBSYSTEM=="block"' \
  "$PROJECT_DIR/host/udev/99-pi-gateway-jmicron.rules"; then
  die "udev block change storm geri geldi"
fi
grep -q 'nodiscard' "$PROJECT_DIR/scripts/pi/ensure-ssd-fstab.sh" || die "fstab nodiscard yok"
grep -q 'pi-ssd-health.timer' "$PROJECT_DIR/scripts/pi/bootstrap.sh" || die "ssd-health timer bootstrap yok"
ok "udev jmicron"

grep -q 'ssd-alive.sh' "$PROJECT_DIR/scripts/pi/install-privileged-scripts.sh" || die "priv ssd-alive yok"
grep -q 'world-writable' "$PROJECT_DIR/scripts/pi/install-privileged-scripts.sh" || die "priv TOCTOU guard yok"
ok "privileged install"

# cmdline helper: UAS + NO_LPM + autosuspend, duplicate rootwait sil
# shellcheck source=../lib/usb-quirk.sh
source "$PROJECT_DIR/scripts/lib/usb-quirk.sh"
_tmp_cmd="$(mktemp)"
printf '%s\n' 'usb-storage.quirks=152d:0583:u root=PARTUUID=abcd-02 rootfstype=ext4 rootwait console=tty1 rootfstype=ext4 rootwait' >"$_tmp_cmd"
apply_jmicron_cmdline_file "$_tmp_cmd" "152d:0583:u" >/dev/null
_got="$(tr -d '\n' <"$_tmp_cmd")"
echo "$_got" | grep -q 'usbcore.quirks=152d:0583:k' || die "cmdline NO_LPM yok"
echo "$_got" | grep -q 'usbcore.autosuspend=-1' || die "cmdline autosuspend yok"
c_wait="$(echo "$_got" | grep -o 'rootwait' | wc -l | tr -d ' ')"
[[ "$c_wait" == "1" ]] || die "rootwait dedupe fail: $c_wait"
[[ ! -e "${_tmp_cmd}.tmp-jmicron" ]] || die "cmdline tmp leftover"
got="$(usbcore_quirk_from_storage '152d:0583')"
[[ "$got" == "152d:0583:k" ]] || die "usbcore quirk no-:u: $got"
got="$(usbcore_quirk_from_storage '152d:0583:u')"
[[ "$got" == "152d:0583:k" ]] || die "usbcore quirk :u: $got"
got="$(usbcore_quirk_from_storage 'evil;reboot')"
[[ "$got" == "152d:0583:k" ]] || die "usbcore quirk garbage: $got"
got="$(normalize_storage_quirk '152d:0583')"
[[ "$got" == "152d:0583:u" ]] || die "normalize storage: $got"
printf '%s\n' 'root=PARTUUID=abcd-02 rootwait' >"$_tmp_cmd"
apply_jmicron_cmdline_file "$_tmp_cmd" "152d:0583" >/dev/null
_got="$(tr -d '\n' <"$_tmp_cmd")"
echo "$_got" | grep -q 'usb-storage.quirks=152d:0583:u' || die "normalize :u cmdline yok"
echo "$_got" | grep -q 'usbcore.quirks=152d:0583:k' || die "normalize :k cmdline yok"
ssd_usb_port_path_ok "/tmp/evil" && die "port path /tmp kabul"
ssd_usb_port_path_ok "/sys/class/net/eth0" && die "port path eth0 kabul"
rm -f "$_tmp_cmd"
ok "jmicron cmdline helper"

if ssd_mount_healthy 2>/dev/null; then
  die "Mac'te ssd_mount_healthy true dondu (beklenmez)"
fi
ok "ssd_mount_healthy Mac'te fail"

echo "[test-ssd-alive] Tum testler gecti"
