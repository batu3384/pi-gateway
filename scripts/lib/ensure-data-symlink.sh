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
# Degraded SD agaci — SSD restore'da rsync ile SSD'ye YAZILMAZ (clobber korumasi)
SD_DEGRADED_MARKER=".pi-gateway-sd-degraded-ephemeral"

if [[ "${2:-}" == "--fallback-sd" || "${1:-}" == "--fallback-sd" ]]; then
  FALLBACK_SD=true
  [[ "$MODE" == "--fallback-sd" ]] && MODE="repair"
fi

log() { echo "[data-symlink] $*"; }
die() { log "HATA: $*"; exit 1; }

run_as_needed() {
  if [[ "$(id -u)" -eq 0 ]]; then
    "$@"
  else
    sudo "$@"
  fi
}

if [[ -f "${REMOTE_DIR}/.env" ]]; then
  # shellcheck source=/dev/null
  source "${REMOTE_DIR}/.env"
  STORAGE_TYPE="${STORAGE_TYPE:-hybrid}"
fi

# Stale mount = mountpoint true ama I/O olu — degraded clear YASAK
_SYMLINK_LIB="$(cd "$(dirname "${BASH_SOURCE[0]:-$0}")" && pwd)"
if [[ -f "${_SYMLINK_LIB}/ssd-alive.sh" ]]; then
  # shellcheck source=ssd-alive.sh
  source "${_SYMLINK_LIB}/ssd-alive.sh"
fi
unset _SYMLINK_LIB

ssd_ready_for_symlink() {
  if declare -F ssd_mount_healthy >/dev/null 2>&1; then
    ssd_mount_healthy
  else
    mountpoint -q /mnt/ssd 2>/dev/null
  fi
}

needs_ssd_symlink() {
  # ssd-root: native data/ (symlink yok) — root zaten SSD
  [[ "${STORAGE_TYPE}" == "hybrid" || "${STORAGE_TYPE}" == "ssd-data" ]]
}

dns_degraded_allowed() {
  [[ "${DNS_DEGRADED_ON_SSD_LOSS:-true}" == "true" ]] \
    || [[ "${STORAGE_FALLBACK_SD:-false}" == "true" ]]
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

# Degraded SD agacini kenara al — SSD uzerine rsync YOK
discard_ephemeral_sd_data() {
  local local_data="${REMOTE_DIR}/data"
  local bak="${REMOTE_DIR}/data.sd-degraded.bak.$$"
  log "Degraded SD data SSD'ye yazilmiyor (clobber korumasi) — kenara: $bak"
  run_as_needed mv "$local_data" "$bak"
  # Eski bak'lari sinirla (en fazla 2)
  local bak_list bak_count=0
  bak_list="$(ls -1d "${REMOTE_DIR}"/data.sd-degraded.bak.* 2>/dev/null | sort || true)"
  if [[ -n "$bak_list" ]]; then
    bak_count="$(printf '%s\n' "$bak_list" | wc -l | tr -d ' ')"
    if (( bak_count > 2 )); then
      printf '%s\n' "$bak_list" | head -n "$((bak_count - 2))" | while read -r old; do
        [[ -n "$old" ]] || continue
        run_as_needed rm -rf "$old" 2>/dev/null || true
      done
    fi
  fi
}

repair_symlink() {
  ssd_ready_for_symlink || die "SSD bagli/saglikli degil (/mnt/ssd)"

  ensure_tree_on "${DATA_ROOT}"

  if [[ -d "${REMOTE_DIR}/data" && ! -L "${REMOTE_DIR}/data" ]]; then
    if [[ -f "${REMOTE_DIR}/data/${SD_DEGRADED_MARKER}" ]]; then
      discard_ephemeral_sd_data
    elif [[ -n "$(ls -A "${REMOTE_DIR}/data" 2>/dev/null)" ]]; then
      # Ilk kurulum / legacy: SD'de gercek veri kalintisi — SSD'ye tasi
      log "SD karttaki kalici data SSD'ye tasiniyor -> ${DATA_ROOT}"
      rsync -a "${REMOTE_DIR}/data/" "${DATA_ROOT}/"
      run_as_needed rm -rf "${REMOTE_DIR}/data"
    else
      run_as_needed rm -rf "${REMOTE_DIR}/data"
    fi
  fi

  ln -sfn "${DATA_ROOT}" "${REMOTE_DIR}/data"
  # Flag clear: root veya sudo ile (owner yazamazsa takili kalmasin)
  if [[ -f "$STORAGE_DEGRADED_FLAG" ]]; then
    rm -f "$STORAGE_DEGRADED_FLAG" 2>/dev/null \
      || run_as_needed rm -f "$STORAGE_DEGRADED_FLAG" 2>/dev/null \
      || log "WARN: degraded flag silinemedi: $STORAGE_DEGRADED_FLAG"
  fi
  log "Symlink: ${REMOTE_DIR}/data -> ${DATA_ROOT}"
}

repair_fallback_sd() {
  log "SD fallback data dizini (ephemeral — SSD restore'da rsync edilmez)"
  if [[ -L "${REMOTE_DIR}/data" ]]; then
    rm -f "${REMOTE_DIR}/data"
  fi
  ensure_tree_on "${REMOTE_DIR}/data"
  touch "${REMOTE_DIR}/data/${SD_DEGRADED_MARKER}"
  mkdir -p "$(dirname "$STORAGE_DEGRADED_FLAG")" 2>/dev/null || true
  if ! touch "$STORAGE_DEGRADED_FLAG" 2>/dev/null; then
    run_as_needed mkdir -p "$(dirname "$STORAGE_DEGRADED_FLAG")"
    run_as_needed touch "$STORAGE_DEGRADED_FLAG"
    # Sonraki owner clear icin sahiplik
    local owner
    owner="$(stat -c '%U' "$REMOTE_DIR" 2>/dev/null || echo "${USER:-pi}")"
    run_as_needed chown -R "${owner}:${owner}" "$(dirname "$STORAGE_DEGRADED_FLAG")" 2>/dev/null || true
  fi
  log "OK: yerel data (degraded) -> ${REMOTE_DIR}/data"
}

ensure_local_data() {
  ensure_tree_on "${REMOTE_DIR}/data"
}

main() {
  mkdir -p "${REMOTE_DIR}"

  if needs_ssd_symlink; then
    if ! ssd_ready_for_symlink; then
      if [[ "$FALLBACK_SD" == "true" ]] || dns_degraded_allowed; then
        if [[ "${MODE}" == "verify" ]]; then
          verify_local_data || die "SD fallback data yok"
          log "OK: SD fallback data"
          exit 0
        fi
        repair_fallback_sd
        exit 0
      fi
      die "SSD bagli degil (/mnt/ssd) ve DNS_DEGRADED_ON_SSD_LOSS/STORAGE_FALLBACK_SD kapali"
    fi

    if verify_symlink; then
      # Symlink OK ama ephemeral flag/dir kalintisi olmamali — yalniz SSD saglikliyken
      if [[ -f "$STORAGE_DEGRADED_FLAG" ]]; then
        rm -f "$STORAGE_DEGRADED_FLAG" 2>/dev/null \
          || run_as_needed rm -f "$STORAGE_DEGRADED_FLAG" 2>/dev/null || true
        log "WARN: symlink OK ama degraded flag vardi — temizlendi"
      fi
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
