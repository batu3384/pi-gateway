#!/usr/bin/env bash
# DNS/filtre tune (post-deploy yok). Unbound recreate yalnız conf stale ise.
set -euo pipefail
REMOTE_DIR="${REMOTE_DIR:-/home/${USER}/pi-gateway}"
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
_PG_ENV_LIB="${SCRIPT_DIR}/../lib/env-file.sh"
PG_SCRIPT_NAME="$(basename "$0")"
# shellcheck source=../lib/env-file.sh
source "${_PG_ENV_LIB:?}"
read_remote_dotenv || { echo "[${PG_SCRIPT_NAME:-script}] HATA: .env dotenv parser hatasi" >&2; exit 1; }
# shellcheck source=../lib/stack-health.sh
source "$SCRIPT_DIR/../lib/stack-health.sh"

log() { echo "[adguard-tune] $*"; }

REMOTE_DIR="$REMOTE_DIR" bash "$SCRIPT_DIR/ensure-ipv6-ula.sh"
REMOTE_DIR="$REMOTE_DIR" bash "$SCRIPT_DIR/setup-rdnss-ra.sh"
REMOTE_DIR="$REMOTE_DIR" bash "$SCRIPT_DIR/setup-firewall.sh"
REMOTE_DIR="$REMOTE_DIR" bash "$SCRIPT_DIR/setup-adguard-timers.sh"

cd "$REMOTE_DIR/compose"
if ! docker inspect unbound >/dev/null 2>&1 || unbound_conf_stale; then
  log "Unbound recreate (conf stale veya container yok)"
  docker compose --env-file ../.env up -d --force-recreate --no-deps unbound
else
  log "Unbound conf taze — recreate yok"
fi
docker compose --env-file ../.env up -d adguard
REMOTE_DIR="$REMOTE_DIR" bash "$SCRIPT_DIR/apply-adguard-dns.sh"
REMOTE_DIR="$REMOTE_DIR" bash "$SCRIPT_DIR/ensure-adguard-blocking.sh" --fix
log "Tamamlandi"
