#!/usr/bin/env bash
# Docker data-root'u USB SSD'ye tasir (hybrid: OS SD'de, imaj metadata SSD'de)
# Docker 29+ containerd snapshot store varsayilan /var/lib/containerd (SD) kalir —
# USB SSD (JMicron) uzerinde containerd root bazi imajlarda segfault (homepage).
# Tam containerd tasima: CONTAINERD_ON_SSD=true (deneysel, non-JMicron).
set -euo pipefail
REMOTE_DIR="${REMOTE_DIR:-/home/${USER}/pi-gateway}"
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
_PG_ENV_LIB="${SCRIPT_DIR:-$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)}/../lib/env-file.sh"
PG_SCRIPT_NAME="$(basename "$0")"
# shellcheck source=../lib/env-file.sh
source "${_PG_ENV_LIB:?}"
read_remote_dotenv || { echo "[${PG_SCRIPT_NAME:-script}] HATA: .env dotenv parser hatasi" >&2; exit 1; }
# shellcheck source=../lib/containerd-root.sh
source "$SCRIPT_DIR/../lib/containerd-root.sh"
DOCKER_SSD_ROOT="${DOCKER_SSD_ROOT:-/mnt/ssd/docker}"
CONTAINERD_SSD_ROOT="${CONTAINERD_SSD_ROOT:-/mnt/ssd/containerd}"
CONTAINERD_ON_SSD="${CONTAINERD_ON_SSD:-false}"
DOCKER_LEGACY="/var/lib/docker"
MARKER="/mnt/ssd/.docker-data-root"
CONTAINERD_MARKER="/mnt/ssd/.containerd-data-root"
DAEMON_JSON="/etc/docker/daemon.json"
DROPIN_DIR="/etc/systemd/system/docker.service.d"
DROPIN_FILE="${DROPIN_DIR}/pi-gateway-ssd.conf"
log() { echo "[docker-ssd] $*"; }
die() { log "HATA: $*"; exit 1; }
if [[ "$STORAGE_TYPE" == "ssd-root" || "$STORAGE_TYPE" == "ssd" ]]; then
  log "STORAGE_TYPE=${STORAGE_TYPE} — docker zaten rootfs (SSD) uzerinde, atlandi"
  exit 0
fi
[[ "$STORAGE_TYPE" == "hybrid" || "$STORAGE_TYPE" == "ssd-data" ]] || {
  log "STORAGE_TYPE=${STORAGE_TYPE:-?} — SSD docker yalnizca hybrid/ssd-data icin"
  exit 0
}
[[ "${ENABLE_DOCKER_SSD:-false}" == "true" ]] || { log "ENABLE_DOCKER_SSD=false — atlandi"; exit 0; }
mountpoint -q /mnt/ssd || die "/mnt/ssd mount degil — once SSD kurulumu"
already_on_ssd() {
  [[ -f "$MARKER" ]] || return 1
  docker info 2>/dev/null | grep -q "Docker Root Dir: ${DOCKER_SSD_ROOT}" || return 1
  if [[ "$CONTAINERD_ON_SSD" == "true" ]]; then
    [[ -f "$CONTAINERD_MARKER" ]] || return 1
    [[ "$(containerd_root_from_config)" == "$CONTAINERD_SSD_ROOT" ]] || return 1
  else
    [[ "$(containerd_root_from_config)" == "${CONTAINERD_LEGACY_ROOT:-/var/lib/containerd}" ]] || return 1
  fi
  return 0
}
if already_on_ssd; then
  log "Zaten aktif: docker=${DOCKER_SSD_ROOT} containerd=$(containerd_root_from_config)"
  exit 0
fi
pre_cleanup() {
  log "On temizlik (SD alan acma)..."
  sudo apt-get clean -qq 2>/dev/null || true
  docker image rm louislam/uptime-kuma:1 2>/dev/null || true
  docker image prune -f 2>/dev/null || true
}
configure_daemon() {
  log "daemon.json: data-root=${DOCKER_SSD_ROOT}"
  sudo mkdir -p "$DOCKER_SSD_ROOT"
  sudo python3 - "$DAEMON_JSON" "$DOCKER_SSD_ROOT" <<'PY'
import json, sys
from pathlib import Path
path, root = Path(sys.argv[1]), sys.argv[2]
cfg = {}
if path.exists():
    try:
        cfg = json.loads(path.read_text())
    except json.JSONDecodeError:
        cfg = {}
cfg["data-root"] = root
path.write_text(json.dumps(cfg, indent=2) + "\n")
PY
}
configure_containerd() {
  if [[ "$CONTAINERD_ON_SSD" == "true" ]]; then
    log "containerd: root=${CONTAINERD_SSD_ROOT} (CONTAINERD_ON_SSD=true)"
    sudo mkdir -p "$CONTAINERD_SSD_ROOT"
    set_containerd_root "$CONTAINERD_SSD_ROOT"
  else
    log "containerd: SD'de kalir (${CONTAINERD_LEGACY_ROOT}) — USB SSD overlay guvenli degil"
    set_containerd_root "${CONTAINERD_LEGACY_ROOT:-/var/lib/containerd}"
    sudo rm -f "$CONTAINERD_MARKER" 2>/dev/null || true
  fi
}
configure_systemd() {
  log "docker.service: SSD mount tercih (RequiresMountsFor yok — degraded fallback mumkun)"
  sudo mkdir -p "$DROPIN_DIR"
  sudo tee "$DROPIN_FILE" >/dev/null <<'EOF'
[Unit]
After=mnt-ssd.mount local-fs.target
Wants=mnt-ssd.mount
EOF
  sudo systemctl daemon-reload
}
containerd_ssd_populated() {
  [[ -d "${CONTAINERD_SSD_ROOT}/io.containerd.content.v1.content" ]] \
    || [[ -d "${CONTAINERD_SSD_ROOT}/io.containerd.snapshotter.v1.overlayfs" ]]
}
docker_ssd_has_payload() {
  sudo find "$DOCKER_SSD_ROOT" -type f -print -quit 2>/dev/null | grep -q .
}
containerd_ssd_has_payload() {
  sudo find "$CONTAINERD_SSD_ROOT" -type f -print -quit 2>/dev/null | grep -q .
}
migrate_containerd() {
  [[ "$CONTAINERD_ON_SSD" == "true" ]] || return 0
  if containerd_ssd_populated; then
    log "containerd hedef zaten dolu — rsync atlandi"
    return 0
  fi
  containerd_ssd_has_payload && die "containerd SSD hedefi kismen dolu — otomatik birlestirme yok"
  if [[ -d "$CONTAINERD_LEGACY_ROOT" ]] && [[ "$(sudo ls -A "$CONTAINERD_LEGACY_ROOT" 2>/dev/null)" ]]; then
    log "Tasima: ${CONTAINERD_LEGACY_ROOT} -> ${CONTAINERD_SSD_ROOT} (tar pipe)"
    sudo mkdir -p "$CONTAINERD_SSD_ROOT"
    sudo tar -C "$CONTAINERD_LEGACY_ROOT" -cf - . | sudo tar -C "$CONTAINERD_SSD_ROOT" -xf -
    log "containerd tar tamamlandi"
  fi
}
migrate_data() {
  if [[ -d "$DOCKER_LEGACY" ]] && [[ "$(sudo ls -A "$DOCKER_LEGACY" 2>/dev/null)" ]]; then
    if [[ ! -d "${DOCKER_SSD_ROOT}/image" ]] && [[ ! -f "${DOCKER_SSD_ROOT}/engine-id" ]]; then
      docker_ssd_has_payload && die "Docker SSD hedefi kismen dolu — otomatik birlestirme yok"
      log "Tasima: ${DOCKER_LEGACY} -> ${DOCKER_SSD_ROOT}"
      sudo mkdir -p "$DOCKER_SSD_ROOT"
      sudo rsync -aHAX --delete "${DOCKER_LEGACY}/" "${DOCKER_SSD_ROOT}/"
      log "docker rsync tamamlandi"
    else
      log "Docker hedef zaten dolu — rsync atlandi"
    fi
  else
    sudo mkdir -p "$DOCKER_SSD_ROOT"
  fi
}
backup_legacy() {
  if [[ -d "$DOCKER_LEGACY" ]] && [[ ! -L "$DOCKER_LEGACY" ]]; then
    local bak
    bak="${DOCKER_LEGACY}.sd-backup-$(date +%Y%m%d)"
    if [[ ! -d "$bak" ]]; then
      log "Eski docker root yedek: $bak"
      sudo mv "$DOCKER_LEGACY" "$bak"
    fi
  fi
}
backup_legacy_containerd() {
  [[ "$CONTAINERD_ON_SSD" == "true" ]] || return 0
  if [[ -d "$CONTAINERD_LEGACY_ROOT" ]] && [[ ! -L "$CONTAINERD_LEGACY_ROOT" ]]; then
    local bak
    bak="${CONTAINERD_LEGACY_ROOT}.sd-backup-$(date +%Y%m%d)"
    if [[ ! -d "$bak" ]]; then
      log "Eski containerd root yedek: $bak"
      sudo mv "$CONTAINERD_LEGACY_ROOT" "$bak"
    else
      sudo rm -rf "$CONTAINERD_LEGACY_ROOT"
    fi
  fi
}
restart_docker() {
  log "containerd + Docker yeniden baslatiliyor..."
  sudo systemctl stop docker docker.socket containerd 2>/dev/null || true
  sleep 2
  sudo systemctl start containerd || die "containerd baslamadi"
  sudo systemctl start docker
  for _ in 1 2 3 4 5 6 7 8 9 10; do
    docker info >/dev/null 2>&1 && break
    sleep 2
  done
  docker info >/dev/null 2>&1 || die "Docker baslamadi"
}
bring_up_stack() {
  log "Stack yeniden baslatiliyor..."
  cd "${REMOTE_DIR}/compose"
  # shellcheck source=../lib/compose-profiles.sh
  source "${REMOTE_DIR}/scripts/lib/compose-profiles.sh"
  mapfile -t profiles < <(compose_profiles)
  docker compose --env-file ../.env "${profiles[@]}" up -d
}
verify() {
  local root croot
  root="$(docker info 2>/dev/null | awk -F': ' '/Docker Root Dir/{print $2}')"
  [[ "$root" == "$DOCKER_SSD_ROOT" ]] || die "Docker root dogrulanamadi: ${root:-bilinmiyor}"
  croot="$(containerd_root_from_config)"
  if [[ "$CONTAINERD_ON_SSD" == "true" ]]; then
    [[ "$croot" == "$CONTAINERD_SSD_ROOT" ]] || die "containerd root dogrulanamadi: ${croot:-bilinmiyor}"
    echo "$CONTAINERD_SSD_ROOT" | sudo tee "$CONTAINERD_MARKER" >/dev/null
  else
    [[ "$croot" == "${CONTAINERD_LEGACY_ROOT:-/var/lib/containerd}" ]] \
      || die "containerd SD'de degil: ${croot:-bilinmiyor}"
  fi
  df -h / /mnt/ssd | tail -2
  docker system df | head -5
  echo "$DOCKER_SSD_ROOT" | sudo tee "$MARKER" >/dev/null
  log "Dogrulandi: docker=${root} containerd=${croot}"
}
main() {
  pre_cleanup
  configure_daemon
  configure_containerd
  configure_systemd
  log "Docker/containerd durduruluyor..."
  sudo systemctl stop docker docker.socket containerd 2>/dev/null || true
  migrate_data
  migrate_containerd
  restart_docker
  backup_legacy
  backup_legacy_containerd
  if [[ "${SKIP_COMPOSE_UP:-false}" != "true" ]]; then
    bring_up_stack
  else
    log "SKIP_COMPOSE_UP=true — compose recover-ro/hotplug'a birakildi"
  fi
  verify
  log "Tamamlandi — docker SSD; containerd=$(containerd_root_from_config)"
}
main "$@"
