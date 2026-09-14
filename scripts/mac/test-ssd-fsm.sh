#!/usr/bin/env bash
# SSD storage FSM orchestration contracts (C31–C39)
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ROOT="$(cd "$SCRIPT_DIR/../.." && pwd)"
die() { echo "[test-ssd-fsm] HATA: $*" >&2; exit 1; }
ok() { echo "[test-ssd-fsm] OK: $*"; }

docker_ssd="$ROOT/scripts/pi/setup-docker-ssd.sh"
recover="$ROOT/scripts/pi/recover-readonly-root.sh"
hotplug="$ROOT/scripts/pi/ssd-hotplug-handler.sh"
prune="$ROOT/scripts/pi/prune-sd-space.sh"
ssd_health="$ROOT/scripts/pi/ssd-health.sh"
stack_health="$ROOT/scripts/lib/stack-health.sh"

# C31: setup-docker-ssd compose up defer (recover/hotplug owns stack)
grep -q 'SKIP_COMPOSE_UP' "$docker_ssd" || die "C31: SKIP_COMPOSE_UP yok"
grep -A12 'backup_legacy' "$docker_ssd" | grep -q 'SKIP_COMPOSE_UP' \
  || die "C31: SKIP_COMPOSE_UP bring_up_stack gate yok"
ok "C31 setup-docker-ssd SKIP_COMPOSE_UP"
grep -q 'CONTAINERD_SSD_ROOT' "$docker_ssd" || die "C31b: CONTAINERD_SSD_ROOT yok"
grep -q 'containerd-root.sh' "$docker_ssd" || die "C31b: containerd helper yok"
grep -q 'containerd-root.sh' "$ROOT/scripts/pi/setup-docker-fallback.sh" \
  || die "C31b: fallback containerd helper yok"
ok "C31b containerd SSD migrate"

# C31c: systemd privileged recovery includes Docker SSD restore
grep -q 'scripts/pi/setup-docker-ssd.sh' \
  "$ROOT/scripts/pi/install-privileged-scripts.sh" \
  || die "C31c: setup-docker-ssd privileged install yok"
ok "C31c privileged Docker SSD restore"

# C32: recover-ro docker SSD fail-closed (no warn-only)
grep -A12 'setup-docker-ssd.sh' "$recover" | grep -q 'SKIP_COMPOSE_UP=true' \
  || die "C32: recover-ro SKIP_COMPOSE_UP yok"
if grep -A8 'setup-docker-ssd.sh' "$recover" | grep -q 'WARN: docker SSD restore atlandi'; then
  die "C32: recover-ro hala warn-only docker SSD"
fi
grep -A20 'setup-docker-ssd.sh' "$recover" | grep -q 'docker SSD restore basarisiz' \
  || die "C32: recover-ro fail-closed mesaji yok"
ok "C32 recover-ro docker SSD fail-closed"

# C33: degraded clear gate requires docker_ssd_root_ok
grep -q 'docker_ssd_root_ok' "$recover" || die "C33: recover-ro docker_ssd_root_ok yok"
grep -B6 'clear_storage_degraded' "$recover" | grep -q 'docker_ssd_root_ok' \
  || die "C33: clear gate docker_ssd_root_ok icermiyor"
grep -q 'docker_ssd_root_ok()' "$stack_health" || die "C33: stack-health docker_ssd_root_ok yok"
ok "C33 docker_ssd_root_ok gate"
grep -q 'compose_rc' "$recover" || die "C33b: compose recovery failure gate yok"
ok "C33b compose recovery exit propagate"

# C34: hotplug acquires recover lock before restore mutations
grep -q 'recover_lock_acquire' "$hotplug" || die "C34: hotplug recover_lock_acquire yok"
hp_restore="$(awk '/SSD mount OK — tam stack restore/,/mark_stack_recover_cooldown/' "$hotplug")"
echo "$hp_restore" | grep -q 'recover_lock_acquire' || die "C34: restore dalinda lock yok"
lock_line="$(echo "$hp_restore" | grep -n 'recover_lock_acquire' | head -1 | cut -d: -f1)"
symlink_line="$(echo "$hp_restore" | grep -n 'ensure-data-symlink' | head -1 | cut -d: -f1)"
[[ -n "$lock_line" && -n "$symlink_line" ]] || die "C34: lock/symlink satir bulunamadi"
(( lock_line < symlink_line )) || die "C34: lock symlink'den sonra"
ok "C34 hotplug recover lock"

# C35: hotplug recover with SKIP_RECOVER_LOCK (no nested flock deadlock)
grep -q 'SKIP_RECOVER_LOCK=true' "$hotplug" || die "C35: hotplug SKIP_RECOVER_LOCK yok"
grep -q 'SKIP_RECOVER_LOCK' "$stack_health" || die "C35: stack-health SKIP_RECOVER_LOCK destegi yok"
grep -q 'recover_lock_acquire()' "$stack_health" || die "C35: recover_lock_acquire wrapper yok"
grep -q 'recover_lock_release()' "$stack_health" || die "C35: recover_lock_release wrapper yok"
ok "C35 nested recover lock safe"

# C36: prune unused images only when containerd snapshot store is on SD
grep -q 'containerd SD' "$prune" || die "C36: prune containerd SD yolu yok"
grep -q 'containerd SSD' "$prune" || die "C36: prune containerd SSD skip yok"
grep -q 'overlayfs snapshotter' "$prune" || die "C36: Docker 29+ snapshotter notu yok"
! grep -q 'docker data-root SD degil' "$prune" \
  || die "C36: eski docker-root skip (yanlis Docker 29+)"
ok "C36 prune containerd-on-SD aware"
grep -q 'DISK_PRUNE_FORCE_PCT' "$prune" || die "C36c: prune force pct yok"
ok "C36c prune force cooldown bypass"
grep -q 'pi_gateway_containerd_on_ssd' "$ROOT/scripts/pi/export-gateway-state.sh" \
  || die "C36b: containerd_on_ssd metric yok"
grep -q 'pi_gateway_containerd_on_ssd' "$ROOT/config/grafana/provisioning/dashboards/json/pi-gateway.json" \
  || die "C36b: grafana containerd_on_ssd yok"
ok "C36b containerd_on_ssd visibility"

# C37: ssd-health propagates hotplug exit (no || true swallow)
run_hotplug_fn="$(grep -A3 '^run_hotplug()' "$ssd_health")"
echo "$run_hotplug_fn" | grep -q 'ssd-hotplug-handler.sh' || die "C37: run_hotplug handler yok"
echo "$run_hotplug_fn" | grep -q '|| true' && die "C37: run_hotplug hala || true"
grep -q 'HATA: hotplug restore exit' "$ssd_health" \
  || die "C37: hotplug restore failure log yok"
! grep -q 'hotplug exit .*DNS core ayakta' "$ssd_health" \
  || die "C37: hotplug failure DNS ile green yapiliyor"
ok "C37 ssd-health hotplug exit propagate"

# C38: hotplug docker SSD fail-closed + SKIP_COMPOSE_UP
grep -A6 'setup-docker-ssd.sh' "$hotplug" | grep -q 'SKIP_COMPOSE_UP=true' \
  || die "C38: hotplug SKIP_COMPOSE_UP yok"
if grep -A6 'setup-docker-ssd.sh' "$hotplug" | grep -q 'WARN: docker SSD restore atlandi'; then
  die "C38: hotplug warn-only docker SSD"
fi
ok "C38 hotplug docker SSD fail-closed"
grep -q 'compose_rc' "$hotplug" || die "C38b: degraded compose failure gate yok"
ok "C38b degraded compose exit propagate"

# C39: degraded hotplug path also takes recover lock
hp_deg="$(awk '/DNS degraded moda gecis/,/recover_lock_release/' "$hotplug")"
echo "$hp_deg" | grep -q 'recover_lock_acquire' || die "C39: degraded dalinda lock yok"
echo "$hp_deg" | grep -q 'recover_lock_release' || die "C39: degraded dalinda lock release yok"
ok "C39 degraded hotplug lock"

# C40: health-check SSD recover etmez (timer sahip)
grep -q 'SSD_HEALTH_AUTO=false' "$ROOT/scripts/pi/health-check.sh" \
  || die "C40: health-check SSD_HEALTH_AUTO=false yok"
grep -q 'SSD_HEALTH_AUTO=false — aksiyon yok' "$ssd_health" \
  || die "C40: ssd-health gozlem kisa-devre yok"
grep -q 'scripts/pi/ssd-fsck.sh' "$ROOT/scripts/pi/install-privileged-scripts.sh" \
  || die "C40: privileged ssd-fsck yok"
grep -q 'SSD_FSCK_AUTO' "$ssd_health" || die "C40: fsck auto flag yok"
grep -q 'note_fail "ssd-unhealthy"' "$ROOT/scripts/pi/health-check.sh" \
  && die "C40: health-check hâlâ ssd-unhealthy fail"
grep -q 'offsite/drill SLA atlandi' "$ROOT/scripts/pi/health-check.sh" \
  || die "C40: degraded offsite SLA skip yok"
grep -q 'notify_health_systemd_ok' "$ROOT/scripts/lib/notify.sh" \
  || die "C40: health-systemd ok yok"
grep -q 'health_is_slo_fail' "$ROOT/scripts/pi/health-check.sh" \
  || die "C40: SLO fail ayrimi yok"
grep -q 'offsite-\*' "$ROOT/scripts/pi/health-check.sh" \
  || die "C40: offsite soft-exit yok"
ok "C40 health-check SSD gozlem-only"

# C41 (2026-09-13 olayi): fsck sirasinda USB reset/remount yok; canli kilit zorla silinmez;
# son care yalniz calismayan servisleri recreate eder (saglikli DNS durmaz)
ssd_alive="$ROOT/scripts/lib/ssd-alive.sh"
compose_up="$ROOT/scripts/pi/recover-compose-up.sh"
grep -q 'ssd_fsck_in_progress()' "$ssd_alive" || die "C41: ssd_fsck_in_progress yok"
grep -A4 '^ssd_usb_soft_reset()' "$ssd_alive" | grep -q 'ssd_fsck_in_progress' \
  || die "C41: soft-reset fsck guard yok"
grep -A8 '^ssd_try_remount()' "$ssd_alive" | grep -q 'ssd_fsck_in_progress' \
  || die "C41: remount fsck guard yok"
grep -q 'zorla temizle' "$ssd_alive" && die "C41: kilit zorla temizleme geri geldi"
grep -q 'with errors' "$ssd_alive" || die "C41: tune2fs 'clean with errors' tespiti yok"
grep -q 'checksum invalid' "$ssd_alive" || die "C41: EFSBADCRC kmsg tespiti yok"
grep -q -- '--status running' "$compose_up" || die "C41: son care calismayan servis filtresi yok"
grep -q -- '--force-recreate --no-deps "${down_svc\[@\]}"' "$compose_up" \
  || die "C41: son care --no-deps yok"
grep -q 'compose_up --force-recreate --remove-orphans' "$compose_up" \
  && die "C41: son care tum stack force-recreate geri geldi"
grep -q 'notify_write()' "$ROOT/scripts/lib/notify.sh" || die "C41: notify_write (root→owner) yok"
grep -qE 'echo (fail|"\$now"|"\$new_state") > "\$\{?NOTIFY_STATE_DIR|echo "\$now" > "\$NOTIFY_LAST_ALIVE' "$ROOT/scripts/lib/notify.sh" \
  && die "C41: notify state dosyasi notify_write disinda yaziliyor"
ok "C41 fsck/USB reset yarisi + son care + notify owner"

# C42: hotplug debounce stack dusukken restore atlamasin; optional_down Restarting≠Up
grep -A8 'hotplug_debounced' "$hotplug" | grep -q 'stack_core_ok' \
  || die "C42: debounce stack_core_ok yok (20:42 skip restore)"
grep -qE 'Names}} \{\{.Status}}' "$ROOT/scripts/pi/health-check.sh" \
  || die "C42: optional_down Status yok"
grep -qE '\^\$\{name} Up' "$ROOT/scripts/pi/health-check.sh" \
  || die "C42: optional_down Up eslesmesi yok"
ok "C42 hotplug debounce + optional_down Up"

# C43: Restarting≠core; sandbox alpine yok; watchdog durmusu baslatir
grep -q 'true running' "$ROOT/scripts/lib/stack-health.sh" \
  || die "C43: container_health_ok Running sarti yok"
! grep -q 'alpine:latest' "$ROOT/scripts/lib/stack-health.sh" \
  || die "C43: docker_sandbox_ok alpine:latest"
grep -q 'docker start' "$ROOT/scripts/pi/container-restart-watchdog.sh" \
  || die "C43: watchdog durmus konteyner start yok"
grep -q 'docker-socket-proxy' "$ROOT/scripts/lib/stack-health.sh" \
  || die "C43: degraded_stop proxy yok"
ok "C43 sandbox/watchdog/Restarting"

echo "[test-ssd-fsm] Tum kontroller gecti"
