#!/usr/bin/env bash
# Planli SSD ext4 fsck — journal/htree/I/O hatasi sonrasi.
set -euo pipefail
REMOTE_DIR="${REMOTE_DIR:-/home/${USER}/pi-gateway}"
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=../lib/env-file.sh
source "$SCRIPT_DIR/../lib/env-file.sh"
read_remote_dotenv || { echo "[ssd-fsck] HATA: .env" >&2; exit 1; }
# shellcheck source=../lib/stack-health.sh
source "$SCRIPT_DIR/../lib/stack-health.sh"
STATE="${SSD_FSCK_STATE_PATH:-/var/lib/pi-gateway/ssd-fsck-state.json}"
COOLDOWN_SEC="${SSD_FSCK_COOLDOWN_SEC:-604800}"
LOCK="${SSD_FSCK_LOCK:-/run/pi-gateway/ssd-fsck.lock}"
FSCK_LOCK_FD=""
FSCK_LOCK_HELD=false

log() { echo "[ssd-fsck] $*"; }
run_root() {
  if [[ "$(id -u)" -eq 0 ]]; then "$@"; else sudo "$@"; fi
}

ssd_block_dev() {
  findmnt -n -o SOURCE "${SSD_MOUNT:-/mnt/ssd}" 2>/dev/null | head -n1 || true
}

last_run_ts() {
  python3 - "$STATE" <<'PY' 2>/dev/null || echo 0
import json, sys
from pathlib import Path
p = Path(sys.argv[1])
try:
    print(int(json.loads(p.read_text(encoding="utf-8")).get("last_success_at", 0)))
except (OSError, TypeError, ValueError, json.JSONDecodeError):
    print(0)
PY
}

record_success() {
  local detail="$1" device="${2:-}"
  python3 - "$STATE" "$detail" "$device" <<'PY'
import json, sys, time, subprocess
from pathlib import Path
path, detail, device = Path(sys.argv[1]), sys.argv[2], sys.argv[3]
data = {}
if path.is_file():
    try:
        data = json.loads(path.read_text(encoding="utf-8"))
    except (OSError, json.JSONDecodeError):
        data = {}
data["last_success_at"] = int(time.time())
data["last_detail"] = detail
if device:
    data["last_device"] = device
text = json.dumps(data, indent=2) + "\n"
path.parent.mkdir(parents=True, exist_ok=True)
try:
    path.write_text(text, encoding="utf-8")
except PermissionError:
    subprocess.run(["sudo", "tee", str(path)], input=text, text=True, check=True, stdout=subprocess.DEVNULL)
    subprocess.run(["sudo", "chmod", "664", str(path)], check=False)
PY
}

cooldown_ok() {
  local last now
  last="$(last_run_ts)"
  now="$(date +%s)"
  [[ "$last" =~ ^[0-9]+$ ]] && (( now - last >= COOLDOWN_SEC ))
}

_fsck_release() {
  if [[ "${FSCK_LOCK_HELD:-false}" == "true" ]]; then
    flock -u "$FSCK_LOCK_FD" 2>/dev/null || true
    run_root rm -f "$LOCK" 2>/dev/null || true
  fi
  recover_lock_release 2>/dev/null || true
}

_fsck_try_restore_stack() {
  local post_repair
  run_root systemctl start containerd docker 2>/dev/null || true
  sleep 4
  if SKIP_RECOVER_LOCK=true REMOTE_DIR="$REMOTE_DIR" bash "$SCRIPT_DIR/recover-readonly-root.sh"; then
    return 0
  fi
  post_repair="${REMOTE_DIR}/scripts/pi/repair-post-ssd-recovery.sh"
  [[ -f "$post_repair" ]] || post_repair="$SCRIPT_DIR/repair-post-ssd-recovery.sh"
  REMOTE_DIR="$REMOTE_DIR" bash "$post_repair" || true
  if SKIP_RECOVER_LOCK=true REMOTE_DIR="$REMOTE_DIR" bash "$SCRIPT_DIR/recover-readonly-root.sh"; then
    return 0
  fi
  return 1
}

_fsck_abort() {
  local reason="$1"
  log "HATA: $reason"
  _fsck_try_restore_stack || log "WARN: stack restore basarisiz — recover-readonly-root manuel"
  _fsck_release
  exit 1
}

usage() {
  cat <<'EOF'
Kullanim: ssd-fsck.sh [--check|--run|--self-check] [--force]

  --check   fsck gerekli mi (dmesg + tune2fs)
  --run     docker durdur, umount, e2fsck, mount, stack restore
  --force   cooldown atla
EOF
}

if [[ "${1:-}" == "--self-check" ]]; then
  declare -F ssd_filesystem_needs_fsck >/dev/null 2>&1 || exit 1
  grep -q 'stack_dns_core_ok' "$0" || exit 1
  grep -q 'SKIP_RECOVER_LOCK=true' "$0" || exit 1
  grep -q 'REMOTE_DIR}/scripts/pi/repair-post-ssd-recovery.sh' "$0" || exit 1
  grep -q 'last_device' "$0" || exit 1
  log "self-check OK"
  exit 0
fi

if is_ssd_root_mode; then
  log "ssd-root — bu script hybrid/ssd-data icin"
  exit 0
fi
if ! needs_ssd_storage; then
  log "SSD data disk yok — atlandi"
  exit 0
fi

mode="${1:---check}"
force=0
[[ "${2:-}" == "--force" || "${1:-}" == "--force" ]] && force=1
[[ "$mode" == "--force" ]] && mode="--run"

case "$mode" in
  --check)
    if ssd_filesystem_needs_fsck; then
      log "GEREKLI: ext4 journal/htree/I/O hatasi tespit edildi"
      exit 2
    fi
    log "Gerek yok"
    exit 0
    ;;
  --run)
    ;;
  *)
    usage
    exit 1
    ;;
esac

if ! ssd_filesystem_needs_fsck && [[ "$force" -ne 1 ]]; then
  log "fsck gerekli gorunmuyor — --force ile zorla"
  exit 0
fi
if [[ "$force" -ne 1 ]] && ! cooldown_ok; then
  log "cooldown (${COOLDOWN_SEC}s) — --force ile atla"
  exit 1
fi

dev="$(ssd_block_dev)"
dev="${dev//$'\n'/}"
dev="${dev%%$'\r'*}"
[[ -n "$dev" ]] || _fsck_abort "/mnt/ssd block device bulunamadi"
[[ -b "$dev" ]] || _fsck_abort "gecersiz device $dev"

if ! recover_lock_acquire; then
  log "HATA: kurtarma kilidi alinamadi"
  exit 1
fi
trap '_fsck_release' EXIT

ensure_runtime_dir
run_root mkdir -p "$(dirname "$LOCK")"
run_root touch "$LOCK"
if ! exec {FSCK_LOCK_FD}>>"$LOCK"; then
  _fsck_abort "fsck lock acilamadi ($LOCK)"
fi
if ! flock -n "$FSCK_LOCK_FD"; then
  log "HATA: baska fsck calisiyor ($LOCK)"
  exit 1
fi
FSCK_LOCK_HELD=true

log "fsck basliyor: $dev"
set_storage_degraded
if [[ -d "${REMOTE_DIR}/compose" ]]; then
  (cd "${REMOTE_DIR}/compose" && docker compose --env-file ../.env stop) 2>/dev/null \
    || log "WARN: compose stop"
fi
run_root systemctl stop docker docker.socket containerd 2>/dev/null || true
for _ in $(seq 1 20); do
  systemctl is-active docker containerd 2>/dev/null | grep -qE '^(active|activating)$' || break
  sleep 1
done
if systemctl is-active docker containerd 2>/dev/null | grep -qE '^(active|activating)$'; then
  _fsck_abort "docker/containerd durmadi"
fi
sleep 2
if mountpoint -q "${SSD_MOUNT:-/mnt/ssd}" 2>/dev/null; then
  run_root fuser -km "${SSD_MOUNT:-/mnt/ssd}" 2>/dev/null || true
  sleep 2
  run_root umount "${SSD_MOUNT:-/mnt/ssd}" 2>/dev/null \
    || run_root umount -l "${SSD_MOUNT:-/mnt/ssd}" 2>/dev/null \
    || run_root systemctl stop mnt-ssd.mount 2>/dev/null || true
  for _ in $(seq 1 30); do
    mountpoint -q "${SSD_MOUNT:-/mnt/ssd}" 2>/dev/null || break
    sleep 1
  done
fi
if mountpoint -q "${SSD_MOUNT:-/mnt/ssd}" 2>/dev/null; then
  _fsck_abort "/mnt/ssd hala mount"
fi
rc=0
run_root e2fsck -f -y "$dev" || rc=$?
if [[ "$rc" -gt 1 ]]; then
  run_root mount "${SSD_MOUNT:-/mnt/ssd}" 2>/dev/null || run_root systemctl start mnt-ssd.mount 2>/dev/null || true
  _fsck_abort "e2fsck exit $rc"
fi
run_root mount "${SSD_MOUNT:-/mnt/ssd}" 2>/dev/null \
  || run_root systemctl start mnt-ssd.mount 2>/dev/null \
  || _fsck_abort "mount basarisiz"
if ! ssd_mount_healthy; then
  _fsck_abort "mount sonrasi yazma probe fail"
fi
_fsck_try_restore_stack || _fsck_abort "stack restore basarisiz"
if ! stack_dns_core_ok; then
  _fsck_abort "DNS core (adguard+unbound) ayakta degil"
fi
if stack_core_ok 2>/dev/null; then
  clear_storage_degraded || true
fi
record_success "e2fsck -f -y $dev" "$dev"
log "Tamamlandi"
_fsck_release
trap - EXIT
