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
[[ "${SSD_USB_XHCI_AUTO_ON_DROPOUT:-}" == "true" ]] || die "XHCI_AUTO_ON_DROPOUT default true olmali"
grep -q 'ssd_xhci_rebind_enabled' "$SSD_ALIVE" || die "xhci rebind enabled helper yok"
grep -q 'ssd_ghost_block_cleanup' "$SSD_ALIVE" || die "ghost block cleanup yok"
grep -q 'ssd_usb_port_cycle_allowed' "$SSD_ALIVE" || die "undervolt port guard yok"
grep -q 'SSD_USB_XHCI_RESET_STATE_FILE' "$SSD_ALIVE" || die "xhci ayri rate-limit state yok"
grep -q 'degraded_stop_optional_apps' "$HOTPLUG" || die "hotplug degraded_stop_optional_apps yok"
grep -q 'degraded_stop_optional_apps' "$STACK_HEALTH" || die "stack-health degraded_stop_optional_apps yok"
grep -q 'prometheus grafana node-exporter' "$STACK_HEALTH" || die "stack-health monitoring stop listesi yok"
[[ "${SSD_USB_CYCLE_ON_HANG:-}" == "true" ]] || die "CYCLE_ON_HANG default true olmali"
[[ "${SSD_USB_PORT_SCAN_MAX:-}" == "8" ]] || die "PORT_SCAN_MAX default 8 olmali"
grep -q 'ssd_usb_discover_xhci_ports' "$SSD_ALIVE" || die "xhci platform port kesfi yok"
grep -q "find /sys/devices/platform/scb" "$SSD_ALIVE" || die "xhci port find yok"
grep -q "1-1-port" "$SSD_ALIVE" || die "USB2 hub port kesfi yok"
grep -q 'ssd_usb_learn_live_port' "$SSD_ALIVE" || die "port ogrenme yok"
grep -q 'ssd_usb_port_forget' "$SSD_ALIVE" || die "port unutma yok"
grep -q 'SSD_USB_PORT_ROTATE' "$SSD_ALIVE" || die "port rotate yok"
grep -q 'ssd_usb_reset_clear' "$SSD_ALIVE" || die "kota sifir yok"
grep -q 'ssd_usb_discover_usb2_hub_ports' "$SSD_ALIVE" || die "USB2 hub son-care yok"
grep -q 'Hatirlanan port her zaman ilk' "$SSD_ALIVE" || die "ogrenilen port oncelik yok"
grep -q 'ssd_usb_port_fail_record' "$SSD_ALIVE" || die "port fail kayit yok"
grep -q 'ssd_usb_learn_live_port' "$HOTPLUG" || die "hotplug port ogrenme yok"
grep -q 'ssd_usb_reset_lock_stale_clear' "$SSD_ALIVE" || die "stale lock clear yok"
grep -q 'SSD_USB_RESET_LOCK_STALE_SEC' "$SSD_ALIVE" || die "LOCK_STALE_SEC yok"
grep -q 'stat -c %Y' "$SSD_ALIVE" || die "Linux stat -c mtime yok"
grep -q 'trap.*EXIT' "$SSD_ALIVE" || die "soft-reset EXIT trap yok"
grep -q 'OnUnitInactiveSec=90s' "$PROJECT_DIR/host/systemd/pi-ssd-health.timer" \
  || die "ssd-health timer 90s degil"
grep -q 'ssd_usb_disable_lpm' "$SSD_ALIVE" || die "LPM disable yok"
grep -q 'ssd_usb_reset_record_once' "$SSD_ALIVE" || die "rate-limit session yok"
grep -q 'bus-wide cycle basarisiz — rate-limit yakilmiyor' "$SSD_ALIVE" \
  || die "dropout fail rate-limit yakmama yok"
grep -q 'SSD_USB_DROPOUT_PORT_OFF_SEC' "$SSD_ALIVE" || die "dropout OFF sec yok"
grep -q 'ssd_usb_port_bus_wide_cycle' "$SSD_ALIVE" || die "bus-wide cycle yok"
grep -q 'SSD_USB_BUS_WIDE_CYCLE' "$SSD_ALIVE" || die "BUS_WIDE_CYCLE env yok"
grep -q 'xhci zaten unbound' "$SSD_ALIVE" || die "xhci unbound bind yolu yok"
grep -q 'bus dropout + port kota dolu' "$SSD_ALIVE" || die "stuck kota clear yok"
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

# mkdir lock: baska surec tutuyorsa fail (force-clear tek basina gecmez)
_lock_tmp="$(mktemp -d)"
export SSD_USB_RESET_LOCK_DIR="$_lock_tmp/held"
export SSD_USB_RESET_LOCK_WAIT_SEC=0
mkdir "$SSD_USB_RESET_LOCK_DIR"
( cd "$SSD_USB_RESET_LOCK_DIR" && sleep 120 ) &
_lock_holder=$!
if ssd_usb_soft_reset >/dev/null 2>&1; then
  kill "$_lock_holder" 2>/dev/null || true
  wait "$_lock_holder" 2>/dev/null || true
  die "lock varken soft_reset gecti"
fi
kill "$_lock_holder" 2>/dev/null || true
wait "$_lock_holder" 2>/dev/null || true
rmdir "$SSD_USB_RESET_LOCK_DIR" 2>/dev/null || true
unset SSD_USB_RESET_LOCK_DIR SSD_USB_RESET_LOCK_WAIT_SEC
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
grep -q 'PathChanged=' "$PROJECT_DIR/host/systemd/pi-ssd-watch.path" || die "PathChanged yok"
grep -qE 'PathExistsGone|DefaultInstance' "$PROJECT_DIR/host/systemd/pi-ssd-watch.path" \
  && die "gecersiz path unit key"
grep -q 'SYSTEMD_WANTS.*pi-ssd-watch.service' "$PROJECT_DIR/host/udev/99-pi-gateway-jmicron.rules" \
  || die "udev SYSTEMD_WANTS yok"
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
grep -q 'telegram-menu.sh' "$PROJECT_DIR/scripts/lib/telegram-panels.py" \
  || die "telegram-panels CLI caller dokuman yok"
grep -q 'hermes-menu' "$PROJECT_DIR/scripts/lib/telegram-panels.py" \
  || die "telegram-panels hermes-menu caller yok"
grep -q 'grafana' "$PROJECT_DIR/scripts/lib/telegram-panels.py" \
  || die "telegram-panels grafana yok"
PANEL_PROTOCOL='' ENABLE_TLS=true LAN_DOMAIN=home PI_STATIC_IP=192.168.1.50 \
  python3 "$PROJECT_DIR/scripts/lib/telegram-panels.py" panels_json \
  | grep -q 'https://gateway.home' \
  || die "telegram-panels home URL https olmali (ENABLE_TLS)"
PANEL_PROTOCOL='' ENABLE_TLS=true LAN_DOMAIN=home PI_STATIC_IP=192.168.1.50 \
  python3 "$PROJECT_DIR/scripts/lib/telegram-panels.py" self_check \
  || die "telegram-panels self_check fail"
grep -q 'p/grafana' "$PROJECT_DIR/scripts/pi/setup-caddy-lan-ip.sh" \
  || die "caddy-lan-ip grafana path yok"
grep -q 'p/grafana' "$PROJECT_DIR/scripts/pi/setup-tailscale-serve.sh" \
  || die "tailscale-serve grafana path yok"
[[ ! -f "$PROJECT_DIR/scripts/pi/telegram-bot.sh" ]] \
  || die "telegram-bot.sh silinmeli"
[[ ! -f "$PROJECT_DIR/scripts/pi/setup-telegram-bot.sh" ]] \
  || die "setup-telegram-bot.sh silinmeli"
grep -q 'load_telegram_from_hermes' "$PROJECT_DIR/scripts/lib/env-file.sh" \
  || die "load_telegram_from_hermes yok"
grep -q 'Connected to Telegram' "$PROJECT_DIR/scripts/pi/setup-hermes-gateway.sh" \
  || die "hermes setup Connected check yok"
grep -q '_alert_inbox_down' "$PROJECT_DIR/scripts/pi/setup-hermes-gateway.sh" \
  || die "hermes setup inbox-down alarm yok"
grep -q 'enabled birakildi' "$PROJECT_DIR/scripts/pi/setup-hermes-gateway.sh" \
  || die "hermes fail path unit enabled birakmali (poller yok)"
grep -q '_remove_leftover_poller' "$PROJECT_DIR/scripts/pi/setup-hermes-gateway.sh" \
  || die "hermes setup poller cleanup yok"
grep -q 'systemctl restart' "$PROJECT_DIR/scripts/pi/setup-hermes-gateway.sh" \
  || die "hermes setup restart yok"
grep -q 'patch basarisiz' "$PROJECT_DIR/scripts/pi/setup-hermes-gateway.sh" \
  || die "hermes setup patch fail-closed yok"
grep -q 'TELEGRAM_ALLOWED_USERS' "$PROJECT_DIR/scripts/pi/setup-hermes-gateway.sh" \
  || die "hermes setup allowlist preflight yok"
grep -q 'hermes gateway run' "$PROJECT_DIR/host/systemd/hermes-gateway.service" \
  || die "hermes-gateway unit yok"
grep -q 'setup-hermes-gateway.sh' "$PROJECT_DIR/scripts/pi/post-deploy.sh" \
  || die "post-deploy hermes setup yok"
grep -q 'patch-hermes-telegram-pi.sh' "$PROJECT_DIR/scripts/pi/setup-hermes-gateway.sh" \
  || die "hermes setup Pi telegram patch cagirmiyor"
grep -q 'require_progress=False' "$PROJECT_DIR/scripts/pi/patch-hermes-telegram-pi.sh" \
  || die "hermes telegram Pi patch yok"
grep -q 'VERIFY_FAIL\|verified' "$PROJECT_DIR/scripts/pi/patch-hermes-telegram-pi.sh" \
  || die "hermes patch verify yok"
grep -q 'HERMES_TELEGRAM_GATEWAY' "$PROJECT_DIR/.env.example" \
  || die ".env.example Hermes flag yok"
# ENV.md: single TELEGRAM_CHAT_ID row
[[ "$(grep -c 'TELEGRAM_CHAT_ID' "$PROJECT_DIR/docs/ENV.md" || true)" -eq 1 ]] \
  || die "ENV.md TELEGRAM_CHAT_ID tek satir olmali"
grep -q 'prune-sd-space.sh' "$PROJECT_DIR/scripts/pi/install-privileged-scripts.sh" || die "priv prune-sd yok"
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
