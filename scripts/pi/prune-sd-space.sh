#!/usr/bin/env bash
# SD root alan acma — guvenli temizlik (hybrid: Docker SSD veya SD'de olabilir)
set -euo pipefail
REMOTE_DIR="${REMOTE_DIR:-/home/${USER}/pi-gateway}"
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=../lib/env-file.sh
source "$SCRIPT_DIR/../lib/env-file.sh"
read_remote_dotenv || { echo "[prune-sd] HATA: .env dotenv parser hatasi" >&2; exit 1; }
STORAGE_DEGRADED_FLAG="${STORAGE_DEGRADED_FLAG:-/run/pi-gateway/storage-degraded}"
DISK_PRUNE_PCT="${DISK_PRUNE_PCT:-65}"
STAMP="/var/lib/pi-gateway/last-sd-prune"
log() { echo "[prune-sd] $*"; }
root_usage_pct() {
  df / 2>/dev/null | awk 'NR==2 {gsub(/%/,""); print $5}'
}
prune_safe() {
  log "temizlik basliyor..."
  sudo apt-get clean -qq 2>/dev/null || true
  sudo journalctl --vacuum-size=150M 2>/dev/null || true
  if [[ -f "$STORAGE_DEGRADED_FLAG" ]]; then
    log "degraded — docker image prune atlandi"
    return 0
  fi
  local docker_root
  docker_root="$(docker info 2>/dev/null | awk -F': ' '/Docker Root Dir/{print $2; exit}')" || true
  if [[ "${ENABLE_DOCKER_SSD:-false}" == "true" && -n "$docker_root" && "$docker_root" != "/var/lib/docker" ]]; then
    log "docker data-root SD degil (${docker_root}) — image prune atlandi"
    return 0
  fi
  # Kullanilmayan imajlar (calisan container imajlari korunur)
  docker image prune -a -f 2>/dev/null || true
}
usage="$(root_usage_pct)"
[[ -n "${usage:-}" ]] || { log "df / okunamadi"; exit 1; }
if (( usage < DISK_PRUNE_PCT )); then
  log "atlandi: / ${usage}% < ${DISK_PRUNE_PCT}%"
  exit 0
fi
if [[ -f "$STAMP" ]]; then
  age_h="$(python3 -c "import os,time; print(int((time.time()-os.path.getmtime('$STAMP'))//3600))")"
  if (( age_h < 24 )); then
    log "atlandi: son prune ${age_h}h once (24h cooldown)"
    exit 0
  fi
fi
before="${usage}"
prune_safe
after="$(root_usage_pct)"
sudo mkdir -p /var/lib/pi-gateway
sudo touch "$STAMP"
log "tamamlandi: / ${before}% -> ${after}%"
