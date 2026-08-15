#!/usr/bin/env bash
set -euo pipefail
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=../lib/common.sh
source "$SCRIPT_DIR/../lib/common.sh"
load_env
PI_USER="${PI_USER:-pi}"
PI_HOST="${PI_STATIC_IP:-${PI_HOST:-}}"
REMOTE_DIR="${REMOTE_DIR:-/home/$PI_USER/pi-gateway}"
[[ -n "$PI_HOST" ]] || die "PI_STATIC_IP veya PI_HOST gerekli"
echo "=== Pi Gateway Status ($PI_USER@$PI_HOST) ==="
ssh -o ConnectTimeout=10 "$PI_USER@$PI_HOST" "REMOTE_DIR='$REMOTE_DIR' bash -s" <<'REMOTE'
set -euo pipefail
REMOTE_DIR="${REMOTE_DIR:-$HOME/pi-gateway}"
_PG_ENV_LIB="${SCRIPT_DIR:-$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)}/../lib/env-file.sh"
PG_SCRIPT_NAME="$(basename "$0")"
# shellcheck source=../lib/env-file.sh
source "${_PG_ENV_LIB:?}"
read_project_dotenv || { echo "[${PG_SCRIPT_NAME:-script}] HATA: .env dotenv parser hatasi" >&2; exit 1; }
echo "--- uptime ---"
uptime
echo "--- docker ---"
docker ps --format 'table {{.Names}}\t{{.Status}}' | head -20
echo "--- disk ---"
df -h / /mnt/ssd 2>/dev/null | grep -v tmpfs || df -h / | grep -v tmpfs
if [[ "$STORAGE_TYPE" == "hybrid" || "$STORAGE_TYPE" == "ssd-data" ]]; then
  echo "--- data symlink ---"
  if [[ -L "$REMOTE_DIR/data" ]] && [[ "$(readlink -f "$REMOTE_DIR/data")" == "/mnt/ssd/pi-gateway-data" ]]; then
    echo "data -> $(readlink -f "$REMOTE_DIR/data") OK"
  else
    echo "data symlink: BOZUK ($(ls -la "$REMOTE_DIR/data" 2>/dev/null || echo yok))"
  fi
  if [[ -f /mnt/ssd/.docker-data-root ]]; then
    echo "--- docker root ---"
    docker info 2>/dev/null | awk -F': ' '/Docker Root Dir/{print "Docker Root:", $2}'
    du -sh /mnt/ssd/docker 2>/dev/null || true
  fi
fi
echo "--- health ---"
REMOTE_DIR="$REMOTE_DIR" bash "$REMOTE_DIR/scripts/pi/health-check.sh" && echo "health: OK" || echo "health: FAIL"
if [[ -f /var/lib/pi-gateway/state.json ]]; then
  echo "--- gateway state ---"
  python3 -m json.tool /var/lib/pi-gateway/state.json 2>/dev/null || cat /var/lib/pi-gateway/state.json
fi
REMOTE
