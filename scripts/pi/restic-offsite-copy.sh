#!/usr/bin/env bash
# Restic: local SSD repo -> B2/R2 (S3-compatible). Opt-in RESTIC_OFFSITE_ENABLED=true.
set -euo pipefail
REMOTE_DIR="${REMOTE_DIR:-/home/${USER}/pi-gateway}"
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=../lib/stack-health.sh
source "$SCRIPT_DIR/../lib/stack-health.sh"
# shellcheck source=../lib/env-file.sh
source "$SCRIPT_DIR/../lib/env-file.sh"
read_remote_dotenv || { echo "[restic-offsite] HATA: .env dotenv parser hatasi" >&2; exit 1; }

RESTIC_IMAGE="${RESTIC_IMAGE:-restic/restic@sha256:8f5a62b422a2cb1277ea0dd6e826fe1acf649e5b9f02d60e5268d5fd1976255a}"
RESTIC_OFFSITE_COPY_TIMEOUT_SEC="${RESTIC_OFFSITE_COPY_TIMEOUT_SEC:-3600}"
OFFSITE_COPY_MARKER="${OFFSITE_COPY_MARKER:-/var/lib/pi-gateway/last-restic-offsite-copy}"
log() { echo "[restic-offsite] $*"; }

[[ "${RESTIC_OFFSITE_ENABLED:-false}" == "true" ]] || { log "atlandi (RESTIC_OFFSITE_ENABLED=false)"; exit 0; }
[[ "${ENABLE_RESTIC:-true}" == "true" ]] || { log "atlandi (ENABLE_RESTIC=false)"; exit 0; }
[[ -n "${RESTIC_PASSWORD:-}" ]] || { log "HATA: RESTIC_PASSWORD bos"; exit 1; }
[[ -n "${RESTIC_OFFSITE_REPOSITORY:-}" ]] || { log "HATA: RESTIC_OFFSITE_REPOSITORY bos"; exit 1; }

if is_ssd_root_mode; then
  LOCAL_REPO="${RESTIC_REPOSITORY:-${REMOTE_DIR}/data/backups/restic}"
else
  LOCAL_REPO="${RESTIC_REPOSITORY:-/mnt/ssd/pi-gateway-data/backups/restic}"
fi

if storage_degraded || ! mountpoint -q /mnt/ssd 2>/dev/null; then
  log "SSD degraded/yok — offsite copy atlandi"
  exit 0
fi
[[ -d "$LOCAL_REPO" ]] || { log "HATA: local repo yok: $LOCAL_REPO"; exit 1; }

AWS_ACCESS_KEY_ID="${RESTIC_OFFSITE_ACCESS_KEY_ID:-${AWS_ACCESS_KEY_ID:-}}"
AWS_SECRET_ACCESS_KEY="${RESTIC_OFFSITE_SECRET_ACCESS_KEY:-${AWS_SECRET_ACCESS_KEY:-}}"
[[ -n "$AWS_ACCESS_KEY_ID" && -n "$AWS_SECRET_ACCESS_KEY" ]] \
  || { log "HATA: RESTIC_OFFSITE_ACCESS_KEY_ID / RESTIC_OFFSITE_SECRET_ACCESS_KEY bos"; exit 1; }

export RESTIC_PASSWORD AWS_ACCESS_KEY_ID AWS_SECRET_ACCESS_KEY
log "copy: local:$LOCAL_REPO -> ${RESTIC_OFFSITE_REPOSITORY}"
if ! timeout "$RESTIC_OFFSITE_COPY_TIMEOUT_SEC" docker run --rm --network host \
  -e RESTIC_PASSWORD \
  -e AWS_ACCESS_KEY_ID \
  -e AWS_SECRET_ACCESS_KEY \
  -e RESTIC_REPOSITORY="${RESTIC_OFFSITE_REPOSITORY}" \
  -v "${LOCAL_REPO}:/local:ro" \
  "$RESTIC_IMAGE" \
  copy --from-repo "local:/local"; then
  log "HATA: restic copy basarisiz"
  # shellcheck source=../lib/notify.sh
  source "$SCRIPT_DIR/../lib/notify.sh"
  notify_backup_fail "$(date -Iseconds)" "restic offsite copy failed"
  exit 1
fi

mkdir -p "$(dirname "$OFFSITE_COPY_MARKER")" 2>/dev/null || sudo mkdir -p "$(dirname "$OFFSITE_COPY_MARKER")"
if [[ "$(id -u)" -eq 0 ]]; then
  date -Iseconds >"$OFFSITE_COPY_MARKER"
else
  date -Iseconds | sudo tee "$OFFSITE_COPY_MARKER" >/dev/null
fi
log "Tamamlandi — marker $OFFSITE_COPY_MARKER"
