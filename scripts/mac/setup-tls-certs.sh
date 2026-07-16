#!/usr/bin/env bash
# Mac: mkcert ile *.home sertifikasi + Pi'ye sync (tarayici yesil kilit)
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=../lib/common.sh
source "$SCRIPT_DIR/../lib/common.sh"
load_env

PI_USER="${PI_USER:-batu}"
PI_STATIC_IP="${PI_STATIC_IP:-192.168.1.112}"
REMOTE_DIR="${REMOTE_DIR:-/home/${PI_USER}/pi-gateway}"
LAN_DOMAIN="${LAN_DOMAIN:-home}"
CERT_DIR="$PROJECT_DIR/config/caddy/certs"
CERT_FILE="${CERT_DIR}/${LAN_DOMAIN}.pem"
KEY_FILE="${CERT_DIR}/${LAN_DOMAIN}-key.pem"

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
  "git.${LAN_DOMAIN}"
  "sync.${LAN_DOMAIN}"
  "n8n.${LAN_DOMAIN}"
  "logs.${LAN_DOMAIN}"
)

log "Sertifika uretiliyor: ${hosts[*]}"
mkcert -cert-file "$CERT_FILE" -key-file "$KEY_FILE" "${hosts[@]}"

chmod 644 "$CERT_FILE"
chmod 600 "$KEY_FILE"

log "Caddy config render..."
"$SCRIPT_DIR/render-config.sh"

log "Pi'ye gonderiliyor..."
ssh "${PI_USER}@${PI_STATIC_IP}" "mkdir -p ${REMOTE_DIR}/config/caddy/certs"
scp "$CERT_FILE" "$KEY_FILE" \
  "${PI_USER}@${PI_STATIC_IP}:${REMOTE_DIR}/config/caddy/certs/"
scp "$PROJECT_DIR/compose/docker-compose.yml" \
  "${PI_USER}@${PI_STATIC_IP}:${REMOTE_DIR}/compose/docker-compose.yml"

log "Caddy yeniden baslatiliyor..."
ssh "${PI_USER}@${PI_STATIC_IP}" \
  "cd ${REMOTE_DIR}/compose && docker compose --profile caddy up -d caddy --force-recreate"

sleep 3
code="$(curl -sk -o /dev/null -w '%{http_code}' "https://gateway.${LAN_DOMAIN}/" || echo 000)"
log "Test https://gateway.${LAN_DOMAIN} -> HTTP ${code}"
if ! curl -fsS -o /dev/null "https://gateway.${LAN_DOMAIN}/"; then
  log "WARN: Mac henuz CA'ya guvenmiyor olabilir."
  open "$(mkcert -CAROOT)/rootCA.pem"
  log "Anahtar Zinciri: mkcert development CA -> Guven -> SSL: Her Zaman Guven"
fi
log "mkcert CA: $(mkcert -CAROOT)/rootCA.pem"
log "Tamam. Tarayiciyi tamamen kapat-ac (Cmd+Q)."
