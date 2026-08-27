#!/usr/bin/env bash
# Adversarial BLOCK/WARNING regression contracts (C1–C6, key W*)
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ROOT="$(cd "$SCRIPT_DIR/../.." && pwd)"
die() { echo "[test-adversarial] HATA: $*" >&2; exit 1; }
ok() { echo "[test-adversarial] OK: $*"; }

compose_up="$ROOT/scripts/pi/recover-compose-up.sh"
restic="$ROOT/scripts/pi/restic-backup.sh"
pull="$ROOT/scripts/mac/backup-pull.sh"
recover="$ROOT/scripts/pi/recover-readonly-root.sh"
hotplug="$ROOT/scripts/pi/ssd-hotplug-handler.sh"
symlink="$ROOT/scripts/lib/ensure-data-symlink.sh"
post="$ROOT/scripts/pi/post-deploy.sh"
health="$ROOT/scripts/pi/health-check.sh"
deploy="$ROOT/scripts/mac/deploy.sh"
restore="$ROOT/scripts/mac/restore-check.sh"
smoke="$ROOT/scripts/pi/smoke-test.sh"
firewall="$ROOT/scripts/pi/setup-firewall.sh"
install_priv="$ROOT/scripts/pi/install-privileged-scripts.sh"
sync_cfg="$ROOT/scripts/mac/sync-rendered-configs.sh"
predeploy="$ROOT/scripts/mac/pre-deploy-check.sh"
ssd_setup="$ROOT/scripts/pi/setup-ssd-data.sh"
docker_fallback="$ROOT/scripts/pi/setup-docker-fallback.sh"
prune_sd_space="$ROOT/scripts/pi/prune-sd-space.sh"
backup_snapshot="$ROOT/scripts/pi/backup.sh"
env_loader="$ROOT/scripts/lib/env-file.sh"
health_unit="$ROOT/host/systemd/pi-gateway-health.service"
compose="$ROOT/compose/docker-compose.yml"
tailscale_acl="$ROOT/config/tailscale/acl.hujson.example"
tailscale_acl_script="$ROOT/scripts/pi/setup-tailscale-acl.sh"
tailscale_remote="$ROOT/scripts/pi/setup-tailscale-remote.sh"

# C1: force-recreate fail must not finish_ok / cooldown
tail_force="$(tail -n 25 "$compose_up")"
echo "$tail_force" | grep -qE 'finish_fail|exit 1' || die "C1: force-recreate fail exit yok"
if echo "$tail_force" | grep -A2 'force-recreate' | grep -q '^finish_ok$'; then
  die "C1: force-recreate sonrasi kosulsuz finish_ok"
fi
grep -q 'finish_fail' "$compose_up" || die "C1: finish_fail yok"
ok "C1 recover-compose fail-closed"

# C2: reinit must not notify_backup_ok; pull refuses shrink/--delete blind
grep -A25 'repo kurtarilamadi' "$restic" | grep -q 'notify_backup_ok' \
  && die "C2: reinit yolunda notify_backup_ok"
grep -q 'restic-reinit\|RESTIC_REINIT' "$restic" || die "C2: reinit marker yok"
grep -q 'stage_root\|atomic' "$pull" || die "C2: backup-pull staging yok"
grep -q 'snapshot\|refuse\|REINIT\|fewer\|az' "$pull" || die "C2: pull shrink/reinit gate yok"
ok "C2 restic reinit + pull gate"

# C3: ensure_ssd_mounted no clear on mountpoint alone
ensure_fn="$(grep -A25 '^ensure_ssd_mounted()' "$recover")"
echo "$ensure_fn" | grep -q 'ssd_mount_healthy' || die "C3: ensure_ssd_mounted ssd_mount_healthy kullanmiyor"
if echo "$ensure_fn" | grep -q 'clear_storage_degraded'; then
  die "C3: ensure_ssd_mounted hala clear_storage_degraded cagiriyor"
fi
ok "C3 ensure_ssd_mounted no premature clear"

# C4: hotplug clear only after successful recover
hp="$(grep -n 'clear_storage_degraded\|notify_ssd_restored\|recover_script_path\|recover-readonly' "$hotplug")"
clear_line="$(echo "$hp" | grep clear_storage_degraded | head -1 | cut -d: -f1)"
recover_line="$(echo "$hp" | grep -E 'recover_script_path|recover-readonly' | head -1 | cut -d: -f1)"
notify_line="$(echo "$hp" | grep notify_ssd_restored | head -1 | cut -d: -f1)"
[[ -n "$clear_line" && -n "$recover_line" ]] || die "C4: clear/recover satir bulunamadi"
(( clear_line > recover_line )) || die "C4: clear_storage_degraded recover'dan once"
[[ -n "$notify_line" ]] && (( notify_line > clear_line )) || die "C4: notify clear'dan once"
ok "C4 hotplug clear-after-recover"

# C5: CrowdSec/ACL not run_step_soft
if grep -E 'run_step_soft.*(CrowdSec|Tailscale ACL)|(CrowdSec|Tailscale ACL).*run_step_soft' "$post"; then
  die "C5: CrowdSec/ACL hala soft-fail"
fi
grep 'Tailscale ACL' "$post" | grep -qE 'run_step_optional|run_step_critical' \
  || die "C5: Tailscale ACL optional/critical degil"
grep 'CrowdSec"' "$post" | grep -qE 'run_step_optional|run_step_critical' \
  || die "C5: CrowdSec optional/critical degil"
ok "C5 security steps not soft"

# C6: symlink timer must not auto-enter degraded without --fallback-sd / existing flag
main_fb="$(grep -A25 'if ! ssd_ready_for_symlink' "$symlink")"
echo "$main_fb" | grep -q 'FALLBACK_SD' || die "C6: FALLBACK_SD gate yok"
echo "$main_fb" | grep -q 'STORAGE_DEGRADED_FLAG' || die "C6: existing-flag gate yok"
grep -A12 '^repair_symlink()' "$symlink" | grep -qE 'STORAGE_DEGRADED_FLAG|clear_storage' \
  && die "C6: repair_symlink hala degraded flag siliyor"
grep -q 'SYMLINK_LOCK_FILE\|flock.*SYMLINK_LOCK' "$symlink" \
  || die "C6: symlink writer lock yok"
ok "C6 symlink no dual-writer degrade"

# C7: degraded state must not be treated as full healthy before restore
grep -q '! storage_restore_pending && stack_fully_healthy' "$recover" \
  || die "C7: degraded early healthy exit"
ok "C7 degraded restore cannot early-exit"

# C8: recover path must not clobber SSD symlink with SD fallback
recover_data="$(grep -A35 '^ensure_data_symlink()' "$recover")"
echo "$recover_data" | grep -q 'storage_restore_pending' \
  || die "C8: recover data path lacks SSD health gate"
echo "$recover_data" | grep -q 'elif REMOTE_DIR' \
  && echo "$recover_data" | grep -q -- '--fallback-sd' \
  || die "C8: fallback must be conditional"
ok "C8 restore keeps SSD data symlink"

# C9: health/watchdog recovery entrypoint must exist in privileged tree
grep -q 'scripts/pi/recover-stack.sh' "$install_priv" || die "C9: recover-stack privileged install yok"
ok "C9 recover-stack privileged install"

# C10: initialized SSD mount failure must fail closed
grep -A8 'if \[\[ -f "\$MARKER"' "$ssd_setup" | grep -q 'mount_ssd.*|| true' && \
  die "C10: existing SSD marker mount failure yutuluyor"
grep -A12 'if \[\[ -f "\$MARKER"' "$ssd_setup" | grep -q 'mountpoint' \
  || die "C10: marker branch mount verify yok"
ok "C10 SSD marker mount fail-closed"

# C11: Docker fallback must detect stale/hung SSD
grep -q 'ssd_mount_healthy' "$docker_fallback" || die "C11: Docker fallback stale mount probe yok"
ok "C11 Docker fallback stale-mount safe"

# C12: corrupt Restic repo must not init before repair/reinit decision
grep -q 'RESTIC_REPOSITORY.*corrupt\|repo.*corrupt\|restic.*repair' "$restic" \
  || die "C12: corrupt repo recovery gate yok"
if grep -q 'if ! run_restic snapshots' "$restic" && \
  grep -A4 'if ! run_restic snapshots' "$restic" | grep -q 'run_restic init'; then
  die "C12: corrupt snapshot failure still directly init"
fi
ok "C12 Restic corrupt-repo gate"

# C13: atomic/offsite pull must not combine delete with ignore-errors
grep -q 'rsync.*--delete.*--ignore-errors' "$pull" && \
  die "C13: destructive rsync ignore-errors"
ok "C13 backup-pull destructive delete guarded"
grep -q "adguard/AdGuardHome.yaml" "$pull" \
  || die "C13b: backup-pull AGH runtime yaml exclude yok"

# C14: restore-check remote path must match STORAGE_TYPE/RESTIC_REPOSITORY
grep -q 'RESTIC_REMOTE' "$restore" || die "C14: restore remote path variable yok"
grep -q 'RESTIC_REPOSITORY=/mnt/ssd/pi-gateway-data/backups/restic' "$restore" && \
  die "C14: restore-check hardcoded SSD-data path"
ok "C14 restore path aligned"

# C15: config snapshot must fail instead of printing false success
grep -q 'cp .*|| true' "$backup_snapshot" && die "C15: backup snapshot cp error swallowed"
ok "C15 config snapshot fail-closed"

# C16: privileged/systemd scripts must not shell-evaluate .env
[[ -f "$env_loader" ]] || die "C16: safe env loader yok"
_priv_scripts=(
  scripts/pi/recover-readonly-root.sh
  scripts/pi/ssd-hotplug-handler.sh
  scripts/pi/setup-ssd-data.sh
  scripts/pi/recover-stack.sh
  scripts/pi/health-check.sh
  scripts/pi/bootstrap.sh
  scripts/pi/post-deploy.sh
  scripts/pi/smoke-test.sh
)
for root_script in "${_priv_scripts[@]}"; do
  f="$ROOT/$root_script"
  grep -qE 'source.*\.env|set -a && source' "$f" && die "C16: root script source ediyor: $root_script"
  grep -q 'read_remote_dotenv\|read_dotenv_strict\|load_env_file' "$f" \
    || die "C16: dotenv loader yok: $root_script"
done
ok "C16 root env command execution kapali"

# C17: health failure service is wired
grep -q 'OnFailure=.*pi-gateway-health-failure.service' "$health_unit" \
  || die "C17: health OnFailure wiring yok"
ok "C17 health failure alert wiring"

# C18: forgejo/syncthing removed from compose
grep -qE 'container_name: (forgejo|syncthing)' "$compose" \
  && die "C18: forgejo/syncthing hala compose'da"
ok "C18 forgejo/syncthing removed"

# C19: redis/autoheal/watchtower removed from compose
grep -qE 'container_name: (redis|autoheal|watchtower)' "$compose" \
  && die "C19: redis/autoheal/watchtower hala compose'da"
grep -qE 'ENABLE_(AUTOHEAL|REDIS|WATCHTOWER)' "$ROOT/scripts/lib/compose-profiles.sh" \
  && die "C19: compose-profiles hala redis/autoheal/watchtower"
ok "C19 redis/autoheal/watchtower removed"

# C19b: stack-watchdog + netalertx-names host paths removed
[[ -f "$ROOT/scripts/pi/stack-watchdog.sh" ]] && die "C19b: stack-watchdog.sh hala var"
[[ -f "$ROOT/host/systemd/pi-gateway-stack-watchdog.timer" ]] && die "C19b: stack-watchdog timer hala var"
[[ -f "$ROOT/host/systemd/pi-gateway-netalertx-names.timer" ]] && die "C19b: netalertx-names timer hala var"
[[ -f "$ROOT/scripts/pi/import-adguard-names-to-netalertx.sh" ]] && die "C19b: import-adguard-names hala var"
grep -q 'stack-watchdog.sh' "$ROOT/scripts/pi/install-privileged-scripts.sh" \
  && die "C19b: install-privileged hala stack-watchdog kopyaliyor"
ok "C19b stack-watchdog/netalertx-names removed"

# C20: every compose image is digest pinned
if grep -E '^[[:space:]]+image: ' "$compose" | grep -vq '@sha256:'; then
  die "C20: mutable compose image tag"
fi
awk '/^[[:space:]]+image: .*@sha256:/ {
  split($0, digest, "@sha256:")
  if (length(digest[2]) != 64) bad=1
}
END { exit bad }' "$compose" \
  || die "C20: invalid sha256 digest length"
ok "C20 compose digest pins"

# C21: Tailscale subnet route is least-privilege and SSH excludes root
if grep -q '192\.168\.0\.0/16\|"root"' "$tailscale_acl"; then
  die "C21: broad Tailscale ACL/root SSH access"
fi
grep -q 'YOUR_TAILSCALE_LAN_SUBNET:53,80,443' "$tailscale_acl" \
  || die "C21: Tailscale LAN port allowlist yok"
grep -q 'tag:pi-gateway:53' "$tailscale_acl" \
  || die "C21: Tailscale Pi :53 (global NS) yok"
grep -q '"src": \["group:owners", "tag:owner-device"\]' "$tailscale_acl" \
  || die "C21: ACL src group:owners (tagsiz telefon) yok"
grep -c '"src": \["group:owners", "tag:owner-device"\]' "$tailscale_acl" | grep -qE '^[23]$' \
  || die "C21: ACL src group:owners en az 2 kuralda (pi ports + LAN/ssh)"
grep -q 'tailnet/-' "$ROOT/scripts/pi/setup-tailscale-dns.sh" \
  || die "C21: DNS API tailnet/- (email kesme 404) yok"
grep -q 'tag:pi-gateway' "$ROOT/scripts/pi/setup-tailscale-dns.sh" \
  || die "C21: DNS script Pi tag:pi-gateway yok"
if grep -q 'for port in 22 80 443 53' "$firewall"; then
  die "C21: DNS 53 TCP dongusunde — UDP ayri kural sart"
fi
grep -q 'in on tailscale0 to any port 53 proto udp' "$firewall" \
  || die "C21: UFW tailscale0 :53/udp yok"
grep -q 'in on tailscale0 to any port 53 proto tcp' "$firewall" \
  || die "C21: UFW tailscale0 :53/tcp yok"
grep -q 'DEFAULT_FORWARD_POLICY="DROP"' "$tailscale_remote" \
  || die "C21: Tailscale forward policy DROP yok"
grep -q 'ts-subnet-dns-udp\|ts-subnet-https' "$tailscale_remote" \
  || die "C21: Tailscale route allowlist yok"
grep -q 'LC_ALL=C' "$tailscale_acl_script" \
  || die "C21: Tailscale ACL regex locale sabit degil"
ok "C21 Tailscale least privilege"

# C22: backup service must expose Restic failure to systemd
grep -q 'restic_failed=1\|exit "\$restic_failed"' "$backup_snapshot" \
  || die "C22: backup Restic failure swallowed"
ok "C22 backup failure visible"

# C23: privileged copy checks source stability and final hash
grep -q 'source install sirasinda degisti\|group/world-writable' "$install_priv" \
  || die "C23: privileged source TOCTOU guard yok"
grep -q 'after=.*sha256sum\|install hash uyusmazligi' "$install_priv" \
  || die "C23: installed hash verification yok"
ok "C23 privileged install integrity"

# C24: Restic helper image is immutable by default
grep -q 'restic/restic@sha256:' "$restic" "$pull" "$restore" \
  || die "C24: Restic helper image mutable"
ok "C24 Restic image digest pin"

# C25: deploy must not put Tailscale secret in SSH argv
if grep -q 'ssh .*TAILSCALE_AUTHKEY=' "$deploy"; then
  die "C25: Tailscale auth key SSH argv leak"
fi
ok "C25 deploy secret argv safe"

# C26: management SSH address can differ from LAN service bind address
for deploy_script in "$deploy" "$predeploy" "$sync_cfg"; do
  grep -q 'PI_DEPLOY_HOST' "$deploy_script" \
    || die "C26: Tailscale deploy host override yok: $deploy_script"
done
ok "C26 deploy host override"

# C27: dotenv identifier regex must be locale-stable on the Pi
grep -q 'LC_ALL=C' "$env_loader" \
  || die "C27: dotenv parser locale sabitlemiyor"
ok "C27 dotenv locale stability"

# W1: offsite missing/stale journal+Telegram; DNS birimi exit 0 (ADR-004 optional)
grep -A25 'last-offsite-backup' "$health" | grep -q 'offsite-backup-missing' \
  || die "W1: offsite-backup-missing note_fail yok"
exit_case="$(awk '/exit_code=0/,/^exit /' "$health")"
echo "$exit_case" | grep -q 'optional-\*)' || die "W1: optional soft-exit yok"
echo "$exit_case" | grep -q 'offsite-\*' || die "W1: offsite SLA soft-exit yok"
ok "W1 offsite SLA notify, no systemd fail"

# W3: deploy remove-orphans
grep -E 'up -d.*--remove-orphans|--remove-orphans.*up -d|up -d --remove-orphans' "$deploy" \
  || grep '\-\-remove-orphans' "$deploy" | grep -q 'up' \
  || die "W3: deploy --remove-orphans yok"
ok "W3 deploy remove-orphans"

# W5: restore-check fail if no repo when restic enabled
grep -q 'die\|exit 1' "$restore" || die "W5: restore-check die yok"
grep -A3 'repo yok' "$restore" | grep -q 'exit 0' && die "W5: repo yok hala exit 0"
ok "W5 restore-check fail-closed"

# W7: env merge preserve Pi keys
grep -q 'N8N_ENCRYPTION_KEY\|merge\|preserve' "$deploy" "$sync_cfg" \
  || die "W7: .env Pi key preserve yok"
ok "W7 env merge"

# W8: SSD health restores when SSD healthy while degraded (former stack-watchdog duty)
ssd_health="$ROOT/scripts/pi/ssd-health.sh"
grep -A20 'storage_degraded' "$ssd_health" | grep -q 'ssd_mount_healthy' \
  || die "W8: degraded+SSD healthy restore yok"
ok "W8 ssd-health SSD restore"

# W9: ENABLE_RESTIC default aligned
grep -q 'ENABLE_RESTIC:-true' "$restic" || die "W9: restic default true degil"
ok "W9 RESTIC default"

# W10: smoke fails on CHANGE_ME auth skip for enabled caddy
grep -A15 'CADDY_AUTH_PASSWORD\|auth_pass' "$smoke" | grep -q 'CHANGE_ME' \
  || die "W10: CHANGE_ME check yok"
# Must fail-check when placeholder (run_check fail or die)
grep -A20 'ENABLE_CADDY' "$smoke" | grep -q 'caddy-auth-configured\|CHANGE_ME\|placeholder' \
  || die "W10: placeholder fail path yok"
ok "W10 smoke placeholder fail"

# W2: NetAlertX GraphQL UFW
grep -q 'GRAPHQL\|20214\|NETALERTX_GRAPHQL' "$firewall" || die "W2: GraphQL UFW yok"
grep -q 'pi-gateway dhcp' "$firewall" || die "W2: adguard-dhcp UFW UDP/67 yok"
ok "W2 netalert graphql ufw"

# W4: privileged hash verify at runtime
grep -q 'installed-sha256\|scripts-sha256\|sha256sum -c' "$install_priv" "$smoke" "$health" \
  || die "W4: runtime hash verify yok"
ok "W4 lib hash verify"

# C28: recover-ro must restore Docker SSD (watchdog/health path, not only hotplug)
grep -q 'setup-docker-ssd.sh' "$recover" || die "C28: recover-ro setup-docker-ssd yok"
grep -A20 'ensure_data_symlink' "$recover" | grep -q 'ENABLE_DOCKER_SSD' \
  || die "C28: recover-ro docker SSD gate yok"
grep -A20 'ensure_data_symlink' "$recover" | grep -q 'recover_mode.*full' \
  || die "C28: recover-ro full-mode docker SSD gate yok"
ok "C28 recover-ro docker SSD restore"

# C29: hotplug must not restart docker after setup-docker-ssd (script restarts internally)
if grep -A3 'setup-docker-ssd.sh' "$hotplug" | grep -q 'systemctl restart docker'; then
  die "C29: hotplug kosulsuz docker restart"
fi
ok "C29 hotplug no redundant docker restart"

# C30: prune-sd skips docker prune when storage degraded
grep -q 'STORAGE_DEGRADED_FLAG' "$prune_sd_space" || die "C30: prune degraded flag yok"
grep -A8 'prune_safe' "$prune_sd_space" | grep -q 'degraded' \
  || die "C30: prune degraded docker guard yok"
ok "C30 prune degraded docker guard"

# C28b: recover-ro uses SKIP_COMPOSE_UP (no double compose with setup-docker-ssd)
grep -A6 'setup-docker-ssd.sh' "$recover" | grep -q 'SKIP_COMPOSE_UP=true' \
  || die "C28b: recover-ro SKIP_COMPOSE_UP yok"
ok "C28b recover-ro SKIP_COMPOSE_UP"

echo "[test-adversarial] Tum kontroller gecti"
