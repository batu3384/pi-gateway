#!/usr/bin/env bash
# Mac: mkcert ile *.home sertifikasi + Pi'ye sync (tarayici yesil kilit)
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=../lib/common.sh
source "$SCRIPT_DIR/../lib/common.sh"
load_env

PI_USER="${PI_USER:-pi}"
PI_STATIC_IP="${PI_STATIC_IP:-}"
SSH_HOST="$(deploy_host)"
REMOTE_DIR="${REMOTE_DIR:-/home/${PI_USER}/pi-gateway}"
LAN_DOMAIN="${LAN_DOMAIN:-home}"
CERT_DIR="$PROJECT_DIR/config/caddy/certs"
CERT_FILE="${CERT_DIR}/${LAN_DOMAIN}.pem"
KEY_FILE="${CERT_DIR}/${LAN_DOMAIN}-key.pem"

[[ -n "$SSH_HOST" ]] || die "PI_STATIC_IP veya PI_DEPLOY_HOST gerekli (.env)"

log() { echo "[tls-certs] $*"; }

require_cmd mkcert openssl ssh scp

mkdir -p "$CERT_DIR"

log "mkcert yerel CA kuruluyor (macOS sifre/GUI isteyebilir)..."
if ! mkcert -install 2>/dev/null; then
  log "WARN: mkcert -install otomatik tamamlanamadi."
  log "Anahtar zinciri aciliyor — kok sertifikaya Guven -> Her Zaman Guven de."
  open "$(mkcert -CAROOT)/rootCA.pem"
  sleep 2
fi

hosts=(
  "*.${LAN_DOMAIN}"
  "${LAN_DOMAIN}"
  "gateway.${LAN_DOMAIN}"
  "panel.${LAN_DOMAIN}"
  "status.${LAN_DOMAIN}"
  "dns.${LAN_DOMAIN}"
  "grafana.${LAN_DOMAIN}"
  "logs.${LAN_DOMAIN}"
  "devices.${LAN_DOMAIN}"
)
if [[ "${ENABLE_N8N:-false}" == "true" ]]; then
  hosts+=("n8n.${LAN_DOMAIN}")
fi

log "Sertifika uretiliyor: ${hosts[*]}"
mkcert -cert-file "$CERT_FILE" -key-file "$KEY_FILE" "${hosts[@]}"

chmod 644 "$CERT_FILE"
chmod 600 "$KEY_FILE"

log "Caddy config render..."
"$SCRIPT_DIR/render-config.sh"

log "Pi'ye gonderiliyor..."
ssh "${PI_USER}@${SSH_HOST}" "mkdir -p ${REMOTE_DIR}/config/caddy/certs"
scp "$CERT_FILE" "$KEY_FILE" \
  "${PI_USER}@${SSH_HOST}:${REMOTE_DIR}/config/caddy/certs/"
if [[ -f "$PROJECT_DIR/config/caddy/Caddyfile" ]]; then
  scp "$PROJECT_DIR/config/caddy/Caddyfile" \
    "${PI_USER}@${SSH_HOST}:${REMOTE_DIR}/config/caddy/Caddyfile"
fi
scp "$PROJECT_DIR/compose/docker-compose.yml" \
  "${PI_USER}@${SSH_HOST}:${REMOTE_DIR}/compose/docker-compose.yml"

log "Caddy yeniden baslatiliyor..."
ssh "${PI_USER}@${SSH_HOST}" \
  "cd ${REMOTE_DIR}/compose && docker compose --env-file ../.env --profile caddy up -d caddy --force-recreate"

sleep 3
code="$(curl -sk -o /dev/null -w '%{http_code}' "https://gateway.${LAN_DOMAIN}/" || echo 000)"
log "Test https://gateway.${LAN_DOMAIN} -> HTTP ${code}"
verified_code="$(curl -sS -o /dev/null -w '%{http_code}' "https://gateway.${LAN_DOMAIN}/" 2>/dev/null || echo 000)"
if [[ "$verified_code" != "200" && "$verified_code" != "401" && "$verified_code" != "302" && "$verified_code" != "308" ]]; then
  log "WARN: Mac henuz CA'ya guvenmiyor olabilir (HTTP ${verified_code})."
  open "$(mkcert -CAROOT)/rootCA.pem"
  log "Anahtar Zinciri: mkcert development CA -> Guven -> SSL: Her Zaman Guven"
fi
log "mkcert CA: $(mkcert -CAROOT)/rootCA.pem"
log "Tamam. Tarayiciyi tamamen kapat-ac (Cmd+Q)."
