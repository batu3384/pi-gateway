#!/usr/bin/env bash
# Render edilmis config + .env dosyalarini Pi'ye gonderir
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=../lib/common.sh
source "$SCRIPT_DIR/../lib/common.sh"
load_env

PI_USER="${PI_USER:-batu}"
PI_HOST="${PI_STATIC_IP:-${PI_HOST:-}}"
REMOTE_DIR="${REMOTE_DIR:-/home/$PI_USER/pi-gateway}"

[[ -n "$PI_HOST" ]] || die "PI_STATIC_IP gerekli"

log "Rendered configs -> ${PI_USER}@${PI_HOST}"

scp "$PROJECT_DIR/.env" "${PI_USER}@${PI_HOST}:/tmp/pi-gateway.env"
scp "$PROJECT_DIR/config/adguard/AdGuardHome.yaml" "${PI_USER}@${PI_HOST}:/tmp/AdGuardHome.yaml"
scp "$PROJECT_DIR/config/homepage/services.yaml" "${PI_USER}@${PI_HOST}:/tmp/homepage-services.yaml"
[[ -f "$PROJECT_DIR/config/caddy/Caddyfile" ]] && \
  scp "$PROJECT_DIR/config/caddy/Caddyfile" "${PI_USER}@${PI_HOST}:/tmp/Caddyfile" || true

ssh "${PI_USER}@${PI_HOST}" "REMOTE_DIR='${REMOTE_DIR}' PI_USER='${PI_USER}' bash -s" <<'REMOTE'
set -euo pipefail
R="${REMOTE_DIR:-/home/${PI_USER}/pi-gateway}"
sudo chown "${PI_USER}:${PI_USER}" "${R}/config/adguard/AdGuardHome.yaml" 2>/dev/null || true
cp /tmp/pi-gateway.env "${R}/.env"
cp /tmp/AdGuardHome.yaml "${R}/config/adguard/AdGuardHome.yaml"
cp /tmp/homepage-services.yaml "${R}/config/homepage/services.yaml"
[[ -f /tmp/Caddyfile ]] && cp /tmp/Caddyfile "${R}/config/caddy/Caddyfile"
REMOTE_DIR="${R}" bash "${R}/scripts/pi/fix-config-perms.sh"
if docker ps --format '{{.Names}}' | grep -q '^homepage$'; then
  docker restart homepage >/dev/null 2>&1 || true
fi
REMOTE

log "Tamamlandi"
