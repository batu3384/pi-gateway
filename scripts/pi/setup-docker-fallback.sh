#!/usr/bin/env bash
# SSD yokken Docker data-root'u SD'ye dusurur (degraded DNS modu)
set -euo pipefail
REMOTE_DIR="${REMOTE_DIR:-/home/${USER}/pi-gateway}"
DOCKER_SSD_ROOT="${DOCKER_SSD_ROOT:-/mnt/ssd/docker}"
DOCKER_LEGACY="/var/lib/docker"
DAEMON_JSON="/etc/docker/daemon.json"
DROPIN_DIR="/etc/systemd/system/docker.service.d"
DROPIN_FILE="${DROPIN_DIR}/pi-gateway-ssd.conf"
STORAGE_DEGRADED_FLAG="${STORAGE_DEGRADED_FLAG:-/run/pi-gateway/storage-degraded}"
log() { echo "[docker-fallback] $*"; }
run_root() {
  if [[ "$(id -u)" -eq 0 ]]; then
    "$@"
  else
    sudo "$@"
  fi
}
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=../lib/env-file.sh
source "$SCRIPT_DIR/../lib/env-file.sh"
read_remote_dotenv || { echo "[docker-fallback] HATA: .env dotenv parser hatasi" >&2; exit 1; }
_FALLBACK_REMOTE_DIR="$REMOTE_DIR"
REMOTE_DIR="$_FALLBACK_REMOTE_DIR"
# shellcheck source=../lib/stack-health.sh
source "$SCRIPT_DIR/../lib/stack-health.sh"
if is_ssd_root_mode; then
  log "ssd-root: Docker SD fallback devre disi"
  exit 0
fi
if ssd_mount_healthy; then
  log "SSD mount/probe saglikli — fallback gerekmedi"
  exit 0
fi
log "SSD yok veya stale — Docker SD fallback (/var/lib/docker)"
run_root mkdir -p "$DOCKER_LEGACY"
run_root python3 - "$DAEMON_JSON" "$DOCKER_LEGACY" <<'PY'
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
run_root mkdir -p "$DROPIN_DIR"
run_root tee "$DROPIN_FILE" >/dev/null <<'EOF'
[Unit]
After=local-fs.target
Wants=local-fs.target
EOF
run_root systemctl daemon-reload
mkdir -p "$(dirname "$STORAGE_DEGRADED_FLAG")" 2>/dev/null || true
touch "$STORAGE_DEGRADED_FLAG" 2>/dev/null || true
if systemctl is-active --quiet docker 2>/dev/null; then
  run_root systemctl restart docker || log "WARN: docker restart basarisiz"
fi
log "OK: Docker SD fallback aktif"
