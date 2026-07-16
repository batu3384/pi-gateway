#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=../lib/common.sh
source "$SCRIPT_DIR/../lib/common.sh"
load_env

require_cmd envsubst python3

[[ -n "${AGH_ADMIN_PASSWORD:-}" ]] || die "AGH_ADMIN_PASSWORD must be set in .env"
[[ -n "${AGH_ADMIN_USER:-}" ]] || die "AGH_ADMIN_USER must be set in .env"

if [[ -z "${PI_STATIC_IP:-}" || -z "${LAN_GATEWAY:-}" || -z "${LAN_SUBNET_CIDR:-}" ]]; then
  die "Missing network vars. Run: ./scripts/mac/discover-remote.sh"
fi

export AGH_ADMIN_USER ADGUARD_WEB_PORT="${ADGUARD_WEB_PORT:-8080}" DOZZLE_PORT="${DOZZLE_PORT:-9999}"
export PI_STATIC_IP LAN_DOMAIN="${LAN_DOMAIN:-home}" PI_INTERFACE="${PI_INTERFACE:-eth0}"
export UPTIME_KUMA_STATUS_SLUG="${UPTIME_KUMA_STATUS_SLUG:-pi-gateway}"
if [[ "${ENABLE_TLS:-false}" == "true" ]]; then
  export PANEL_PROTOCOL=https
else
  export PANEL_PROTOCOL=http
fi

HASH="$(generate_password_hash "$AGH_ADMIN_USER" "$AGH_ADMIN_PASSWORD")"

mkdir -p "$PROJECT_DIR/config/adguard" "$PROJECT_DIR/config/homepage" "$PROJECT_DIR/config/caddy"

envsubst '${AGH_ADMIN_USER} ${ADGUARD_WEB_PORT} ${PI_STATIC_IP} ${LAN_DOMAIN} ${PI_INTERFACE}' \
  < "$PROJECT_DIR/config/adguard/AdGuardHome.yaml.template" \
  > "$PROJECT_DIR/config/adguard/AdGuardHome.yaml"

sed -i.bak "s|__PASSWORD_HASH__|$HASH|" "$PROJECT_DIR/config/adguard/AdGuardHome.yaml"
rm -f "$PROJECT_DIR/config/adguard/AdGuardHome.yaml.bak"

if [[ "${NETWORK_MODE:-router-dns}" == "adguard-dhcp" ]]; then
  [[ -n "${DHCP_RANGE_START:-}" && -n "${DHCP_RANGE_END:-}" && -n "${LAN_SUBNET_MASK:-}" ]] \
    || die "DHCP mode requires DHCP_RANGE_* and LAN_SUBNET_MASK"
  DHCP_BLOCK="dhcp:
  enabled: true
  interface_name: ${PI_INTERFACE}
  dhcpv4:
    gateway_ip: ${LAN_GATEWAY}
    subnet_mask: ${LAN_SUBNET_MASK}
    range_start: ${DHCP_RANGE_START}
    range_end: ${DHCP_RANGE_END}
    lease_duration: 86400"
else
  DHCP_BLOCK="dhcp:
  enabled: false"
fi

python3 - "$PROJECT_DIR/config/adguard/AdGuardHome.yaml" "$DHCP_BLOCK" <<'PY'
from pathlib import Path
import sys
path = Path(sys.argv[1])
block = sys.argv[2]
text = path.read_text()
path.write_text(text.replace("__DHCP_BLOCK__", block))
PY

envsubst '${LAN_DOMAIN} ${PI_STATIC_IP} ${DOZZLE_PORT} ${UPTIME_KUMA_STATUS_SLUG} ${PANEL_PROTOCOL}' \
  < "$PROJECT_DIR/config/homepage/services.yaml.template" \
  > "$PROJECT_DIR/config/homepage/services.yaml"

if [[ -f "$PROJECT_DIR/config/homepage/settings.yaml" ]]; then
  :
else
  cat > "$PROJECT_DIR/config/homepage/settings.yaml" <<'EOF'
title: Pi Gateway
theme: dark
color: slate
headerStyle: clean
showStats: true
statusStyle: dot
target: _self
EOF
fi

cat > "$PROJECT_DIR/config/homepage/docker.yaml" <<'EOF'
---
# Docker sock bilerek baglanmiyor (auth'suz panel + sock = Docker API riski).
# Konteyner loglari: logs.home (Dozzle, auth'lu).
EOF

if [[ "${ENABLE_CADDY:-true}" == "true" ]]; then
  caddy_tpl="$PROJECT_DIR/config/caddy/Caddyfile.template"
  if [[ "${ENABLE_TLS:-false}" == "true" ]]; then
    caddy_tpl="$PROJECT_DIR/config/caddy/Caddyfile.tls.template"
    [[ -f "$PROJECT_DIR/config/caddy/certs/${LAN_DOMAIN}.pem" ]] \
      || die "ENABLE_TLS=true but certs missing — run: make tls-certs"
    log "Caddy: HTTPS (mkcert)"
  else
    log "Caddy: HTTP (LAN)"
  fi

  # Hassas paneller (dns/git/sync/n8n/logs) — Caddy basic_auth
  CADDY_AUTH_USER="${CADDY_AUTH_USER:-${AGH_ADMIN_USER:-admin}}"
  CADDY_AUTH_PASSWORD="${CADDY_AUTH_PASSWORD:-${AGH_ADMIN_PASSWORD:-}}"
  [[ -n "$CADDY_AUTH_PASSWORD" ]] || die "CADDY_AUTH_PASSWORD veya AGH_ADMIN_PASSWORD gerekli (Caddy basic_auth)"
  case "$CADDY_AUTH_PASSWORD" in
    CHANGE_ME*|Degistir*|changeme*|password|admin) die "Caddy sifresi varsayilan/placeholder — .env degistir" ;;
  esac
  CADDY_AUTH_HASH="$(generate_password_hash "$CADDY_AUTH_USER" "$CADDY_AUTH_PASSWORD")"
  # htpasswd -nbB ciktisi $2y$... — Caddy basic_auth bcrypt kabul eder
  AUTH_BLOCK="$(printf 'basic_auth {\n\t%s %s\n}' "$CADDY_AUTH_USER" "$CADDY_AUTH_HASH")"

  python3 - "$caddy_tpl" "$PROJECT_DIR/config/caddy/Caddyfile" "$LAN_DOMAIN" "$ADGUARD_WEB_PORT" "$PI_STATIC_IP" "$AUTH_BLOCK" <<'PY'
from pathlib import Path
import sys
src, dst, domain, port, ip, auth = sys.argv[1:7]
text = Path(src).read_text()
text = (text
  .replace("__LAN_DOMAIN__", domain)
  .replace("__ADGUARD_WEB_PORT__", port)
  .replace("__PI_STATIC_IP__", ip)
  .replace("__CADDY_BASIC_AUTH__", auth))
Path(dst).write_text(text)
PY
fi

envsubst '${PI_STATIC_IP} ${LAN_PREFIX} ${LAN_GATEWAY} ${PI_INTERFACE}' \
  < "$PROJECT_DIR/host/dhcpcd/pi-gateway.conf.template" \
  > "$PROJECT_DIR/host/dhcpcd/pi-gateway.conf"

log "Rendered configs for PI_STATIC_IP=$PI_STATIC_IP mode=${NETWORK_MODE:-router-dns}"

if [[ -n "${TELEGRAM_BOT_TOKEN:-}" && -n "${TELEGRAM_CHAT_ID:-}" && -z "${WATCHTOWER_NOTIFICATION_URL:-}" ]]; then
  log "Ipucu: Watchtower icin .env -> WATCHTOWER_NOTIFICATION_URL=telegram://BOT_TOKEN@telegram?chats=CHAT_ID"
fi
