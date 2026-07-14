#!/usr/bin/env bash
# Docker data-root'u USB SSD'ye tasir (hybrid: OS SD'de, imajlar SSD'de)
set -euo pipefail

REMOTE_DIR="${REMOTE_DIR:-/home/${USER}/pi-gateway}"
# shellcheck source=/dev/null
[[ -f "$REMOTE_DIR/.env" ]] && source "$REMOTE_DIR/.env"

DOCKER_SSD_ROOT="${DOCKER_SSD_ROOT:-/mnt/ssd/docker}"
DOCKER_LEGACY="/var/lib/docker"
MARKER="/mnt/ssd/.docker-data-root"
DAEMON_JSON="/etc/docker/daemon.json"
DROPIN_DIR="/etc/systemd/system/docker.service.d"
DROPIN_FILE="${DROPIN_DIR}/pi-gateway-ssd.conf"

log() { echo "[docker-ssd] $*"; }
die() { log "HATA: $*"; exit 1; }

[[ "${STORAGE_TYPE:-hybrid}" == "hybrid" || "${STORAGE_TYPE}" == "ssd-data" ]] || {
  log "STORAGE_TYPE=${STORAGE_TYPE:-?} — SSD docker yalnizca hybrid/ssd-data icin"
  exit 0
}

[[ "${ENABLE_DOCKER_SSD:-true}" == "true" ]] || { log "ENABLE_DOCKER_SSD=false — atlandi"; exit 0; }

mountpoint -q /mnt/ssd || die "/mnt/ssd mount degil — once SSD kurulumu"

if [[ -f "$MARKER" ]] && docker info 2>/dev/null | grep -q "Docker Root Dir: ${DOCKER_SSD_ROOT}"; then
  log "Zaten aktif: ${DOCKER_SSD_ROOT}"
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

configure_systemd() {
  log "docker.service: SSD mount sonrasi baslasin"
  sudo mkdir -p "$DROPIN_DIR"
  sudo tee "$DROPIN_FILE" >/dev/null <<'EOF'
[Unit]
After=mnt-ssd.mount local-fs.target
RequiresMountsFor=/mnt/ssd
EOF
  sudo systemctl daemon-reload
}

migrate_data() {
  if [[ -d "$DOCKER_LEGACY" ]] && [[ "$(sudo ls -A "$DOCKER_LEGACY" 2>/dev/null)" ]]; then
    if [[ ! -d "${DOCKER_SSD_ROOT}/image" ]] && [[ ! -f "${DOCKER_SSD_ROOT}/engine-id" ]]; then
      log "Tasima: ${DOCKER_LEGACY} -> ${DOCKER_SSD_ROOT} (bu birkaç dakika surebilir)"
      sudo mkdir -p "$DOCKER_SSD_ROOT"
      sudo rsync -aHAX --delete "${DOCKER_LEGACY}/" "${DOCKER_SSD_ROOT}/"
      log "rsync tamamlandi"
    else
      log "Hedef zaten dolu — rsync atlandi"
    fi
  else
    log "Kaynak bos — yeni docker root olusturuluyor"
    sudo mkdir -p "$DOCKER_SSD_ROOT"
  fi
}

backup_legacy() {
  if [[ -d "$DOCKER_LEGACY" ]] && [[ ! -L "$DOCKER_LEGACY" ]]; then
    local bak="${DOCKER_LEGACY}.sd-backup-$(date +%Y%m%d)"
    if [[ ! -d "$bak" ]]; then
      log "Eski root yedek: $bak"
      sudo mv "$DOCKER_LEGACY" "$bak"
    fi
  fi
}

restart_docker() {
  log "Docker yeniden baslatiliyor..."
  sudo systemctl stop docker docker.socket containerd 2>/dev/null || true
  sleep 2
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
  # shellcheck source=/dev/null
  source "${REMOTE_DIR}/.env" 2>/dev/null || true
  local profiles=(--profile autoheal --profile caddy --profile dozzle --profile forgejo \
    --profile syncthing --profile redis --profile n8n --profile crowdsec)
  docker compose --env-file ../.env "${profiles[@]}" up -d
}

verify() {
  local root
  root="$(docker info 2>/dev/null | awk -F': ' '/Docker Root Dir/{print $2}')"
  [[ "$root" == "$DOCKER_SSD_ROOT" ]] || die "Root dogrulanamadi: ${root:-bilinmiyor}"
  df -h / /mnt/ssd | tail -2
  docker system df | head -5
  echo "$DOCKER_SSD_ROOT" | sudo tee "$MARKER" >/dev/null
  log "Dogrulandi: Docker Root Dir = $root"
}

main() {
  pre_cleanup
  configure_daemon
  configure_systemd
  log "Docker durduruluyor..."
  sudo systemctl stop docker docker.socket 2>/dev/null || true
  migrate_data
  restart_docker
  backup_legacy
  bring_up_stack
  verify
  log "Tamamlandi — SD kartta ~10GB+ alan acildi"
}

main "$@"
