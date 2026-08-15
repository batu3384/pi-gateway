#!/usr/bin/env bash
# SSD storage FSM chaos drill — dry-run default; live = degraded flag + core-dns + recover
set -euo pipefail
REMOTE_DIR="${REMOTE_DIR:-/home/${USER}/pi-gateway}"
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=../lib/env-file.sh
source "$SCRIPT_DIR/../lib/env-file.sh"
read_remote_dotenv || { echo "[chaos-storage] HATA: .env dotenv parser hatasi" >&2; exit 1; }
# shellcheck source=../lib/stack-health.sh
source "$SCRIPT_DIR/../lib/stack-health.sh"

log() { echo "[chaos-storage] $*"; }
die() { log "HATA: $*"; exit 1; }

DRY_RUN="${CHAOS_DRY_RUN:-true}"
CONFIRM="${CHAOS_CONFIRM:-}"
IP="${PI_STATIC_IP:-127.0.0.1}"

dry_run_checks() {
  [[ -x "$SCRIPT_DIR/recover-compose-up.sh" ]] || die "recover-compose-up.sh yok"
  [[ -x "$SCRIPT_DIR/recover-readonly-root.sh" ]] || die "recover-readonly-root.sh yok"
  declare -F set_storage_degraded >/dev/null 2>&1 || die "set_storage_degraded yok"
  declare -F clear_storage_degraded >/dev/null 2>&1 || die "clear_storage_degraded yok"
  grep -q 'COMPOSE_RECOVER_MODE=core-dns' "$SCRIPT_DIR/recover-compose-up.sh" \
    || die "core-dns recover modu yok"
  log "dry-run OK: FSM scriptleri ve core-dns modu mevcut"
}

live_drill() {
  [[ "$CONFIRM" == "yes" ]] || die "canli drill icin CHAOS_CONFIRM=yes"
  needs_ssd_storage || die "SSD storage kapali — drill anlamsiz"
  ssd_mount_healthy || die "SSD mount sagliksiz — once fiziksel sorunu coz"

  log "live: degraded flag + core-dns"
  set_storage_degraded
  if ! COMPOSE_RECOVER_MODE=core-dns REMOTE_DIR="$REMOTE_DIR" bash "$SCRIPT_DIR/recover-compose-up.sh"; then
    clear_storage_degraded || true
    die "core-dns compose basarisiz"
  fi
  command -v dig >/dev/null 2>&1 \
    && dig +time=3 +tries=2 "@${IP}" cloudflare.com A +short | grep -qE '^[0-9.]+$' \
    || die "DNS cevap vermiyor (degraded sonrasi)"

  log "live: degraded temizle + full recover"
  clear_storage_degraded || die "degraded flag temizlenemedi"
  if ! REMOTE_DIR="$REMOTE_DIR" bash "$SCRIPT_DIR/recover-readonly-root.sh"; then
    die "full recover basarisiz"
  fi
  storage_degraded && die "degraded flag hala aktif"
  log "live drill OK"
}

if [[ "$DRY_RUN" == "true" ]]; then
  dry_run_checks
  exit 0
fi

live_drill
