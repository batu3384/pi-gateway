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

# C36: prune skips docker when data-root not on SD
grep -q 'docker data-root SD degil' "$prune" || die "C36: prune docker root guard yok"
grep -A20 'prune_safe' "$prune" | grep -q 'ENABLE_DOCKER_SSD' \
  || die "C36: prune ENABLE_DOCKER_SSD kontrolu yok"
ok "C36 prune data-root aware"

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

echo "[test-ssd-fsm] Tum kontroller gecti"
