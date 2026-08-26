#!/usr/bin/env bash
# Restic repo onarimi (corrupt pack / prune fail).
set -euo pipefail
REMOTE_DIR="${REMOTE_DIR:-/home/${USER}/pi-gateway}"
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=../lib/stack-health.sh
source "$SCRIPT_DIR/../lib/stack-health.sh"
# shellcheck source=../lib/env-file.sh
source "$SCRIPT_DIR/../lib/env-file.sh"
read_remote_dotenv || { echo "[restic-repair] HATA: .env" >&2; exit 1; }
log() { echo "[restic-repair] $*"; }

[[ "${ENABLE_RESTIC:-true}" == "true" ]] || { log "atlandi"; exit 0; }
[[ -n "${RESTIC_PASSWORD:-}" ]] || { log "HATA: RESTIC_PASSWORD bos"; exit 1; }

if is_ssd_root_mode; then
  RESTIC_REPOSITORY="${RESTIC_REPOSITORY:-${REMOTE_DIR}/data/backups/restic}"
else
  RESTIC_REPOSITORY="${RESTIC_REPOSITORY:-/mnt/ssd/pi-gateway-data/backups/restic}"
fi
RESTIC_IMAGE="${RESTIC_IMAGE:-restic/restic@sha256:8f5a62b422a2cb1277ea0dd6e826fe1acf649e5b9f02d60e5268d5fd1976255a}"
RESTIC_TIMEOUT_SEC="${RESTIC_TIMEOUT_SEC:-7200}"

[[ -d "$RESTIC_REPOSITORY" ]] || { log "repo yok — atlandi"; exit 0; }

run_restic() {
  timeout "$RESTIC_TIMEOUT_SEC" docker run --rm --network none \
    -e RESTIC_PASSWORD \
    -e RESTIC_REPOSITORY=local:/repo \
    -v "${RESTIC_REPOSITORY}:/repo" \
    "$RESTIC_IMAGE" "$@"
}

export RESTIC_PASSWORD
log "unlock"
run_restic unlock 2>/dev/null || true
log "repair index"
run_restic repair index || log "WARN: repair index"
log "repair snapshots"
run_restic repair snapshots 2>/dev/null || true
log "repair packs (yavas olabilir)"
run_restic repair packs 2>/dev/null || log "WARN: repair packs — corrupt pack kalabilir"
if run_restic snapshots --last >/dev/null 2>&1; then
  log "snapshots OK"
else
  log "HATA: repo hala okunamiyor — restic-backup veya RESTIC_ALLOW_REINIT gerekli"
  exit 1
fi
timeout 120 sudo chown -R "${USER}:${USER}" "$RESTIC_REPOSITORY" 2>/dev/null \
  || log "WARN: chown atlandi — backup-pull rsync root dosyalarinda takilabilir"
log "Tamamlandi"
