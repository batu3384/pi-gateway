#!/usr/bin/env bash
# Hybrid modda ~/pi-gateway/data -> /mnt/ssd/pi-gateway-data symlink'ini dogrular/onarir.
# Kullanim: ensure-data-symlink.sh [verify|repair] [--fallback-sd]
set -euo pipefail

REMOTE_DIR="${REMOTE_DIR:-/home/${USER}/pi-gateway}"
STORAGE_TYPE="${STORAGE_TYPE:-hybrid}"
DATA_ROOT="/mnt/ssd/pi-gateway-data"
MODE="${1:-repair}"
FALLBACK_SD=false
STORAGE_DEGRADED_FLAG="${STORAGE_DEGRADED_FLAG:-/run/pi-gateway/storage-degraded}"

if [[ "${2:-}" == "--fallback-sd" || "${1:-}" == "--fallback-sd" ]]; then
  FALLBACK_SD=true
  [[ "$MODE" == "--fallback-sd" ]] && MODE="repair"
fi

log() { echo "[data-symlink] $*"; }
die() { log "HATA: $*"; exit 1; }

if [[ -f "${REMOTE_DIR}/.env" ]]; then
  # shellcheck source=/dev/null
  source "${REMOTE_DIR}/.env"
  STORAGE_TYPE="${STORAGE_TYPE:-hybrid}"
fi

needs_ssd_symlink() {
  # ssd-root: native data/ (symlink yok) — root zaten SSD
  [[ "${STORAGE_TYPE}" == "hybrid" || "${STORAGE_TYPE}" == "ssd-data" ]]
}

data_tree_dirs() {
  printf '%s\n' \
    adguard/work uptime-kuma docker-volumes logs forgejo syncthing netalertx \
    restic projects backups redis n8n crowdsec/config crowdsec/db dozzle .disk-probe
}

verify_symlink() {
  [[ -L "${REMOTE_DIR}/data" ]] && [[ "$(readlink -f "${REMOTE_DIR}/data")" == "${DATA_ROOT}" ]]
}

verify_local_data() {
  [[ -d "${REMOTE_DIR}/data" && ! -L "${REMOTE_DIR}/data" ]]
}

ensure_tree_on() {
  local root="$1"
  local d
  mkdir -p "${root}"
  while IFS= read -r d; do
    mkdir -p "${root}/${d}"
  done < <(data_tree_dirs)
}

repair_symlink() {
  mountpoint -q /mnt/ssd 2>/dev/null || die "SSD bagli degil (/mnt/ssd)"

  ensure_tree_on "${DATA_ROOT}"

  if [[ -d "${REMOTE_DIR}/data" && ! -L "${REMOTE_DIR}/data" ]]; then
    if [[ -n "$(ls -A "${REMOTE_DIR}/data" 2>/dev/null)" ]]; then
      log "SD karttaki data SSD'ye tasiniyor -> ${DATA_ROOT}"
      rsync -a "${REMOTE_DIR}/data/" "${DATA_ROOT}/"
    fi
    if [[ "$(id -u)" -eq 0 ]]; then
      rm -rf "${REMOTE_DIR}/data"
    else
      sudo rm -rf "${REMOTE_DIR}/data"
    fi
  fi

  ln -sfn "${DATA_ROOT}" "${REMOTE_DIR}/data"
  rm -f "$STORAGE_DEGRADED_FLAG" 2>/dev/null || true
  log "Symlink: ${REMOTE_DIR}/data -> ${DATA_ROOT}"
}

repair_fallback_sd() {
  log "SD fallback data dizini"
  if [[ -L "${REMOTE_DIR}/data" ]]; then
    rm -f "${REMOTE_DIR}/data"
  fi
  ensure_tree_on "${REMOTE_DIR}/data"
  mkdir -p "$(dirname "$STORAGE_DEGRADED_FLAG")" 2>/dev/null || true
  touch "$STORAGE_DEGRADED_FLAG" 2>/dev/null || true
  log "OK: yerel data (degraded) -> ${REMOTE_DIR}/data"
}

ensure_local_data() {
  ensure_tree_on "${REMOTE_DIR}/data"
}

main() {
  mkdir -p "${REMOTE_DIR}"

  if needs_ssd_symlink; then
    if ! mountpoint -q /mnt/ssd 2>/dev/null; then
      if [[ "$FALLBACK_SD" == "true" ]] || [[ "${STORAGE_FALLBACK_SD:-false}" == "true" ]]; then
        if [[ "${MODE}" == "verify" ]]; then
          verify_local_data || die "SD fallback data yok"
          log "OK: SD fallback data"
          exit 0
        fi
        repair_fallback_sd
        exit 0
      fi
      die "SSD bagli degil (/mnt/ssd) ve STORAGE_FALLBACK_SD=false"
    fi

    if verify_symlink; then
      log "OK: data -> ${DATA_ROOT}"
      exit 0
    fi

    if [[ "${MODE}" == "verify" ]]; then
      die "data symlink bozuk veya eksik (beklenen: ${DATA_ROOT})"
    fi

    repair_symlink
    verify_symlink || die "onarim sonrasi symlink hala gecersiz"
    log "OK: symlink onarildi"
    exit 0
  fi

  if [[ "${MODE}" == "verify" ]]; then
    [[ -d "${REMOTE_DIR}/data" ]] || die "data dizini yok"
    [[ ! -L "${REMOTE_DIR}/data" ]] || die "ssd modunda data symlink olmamali"
    log "OK: yerel data"
    exit 0
  fi

  ensure_local_data
  log "OK: yerel data hazir"
}

main "$@"
