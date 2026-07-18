#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=../lib/common.sh
source "$SCRIPT_DIR/../lib/common.sh"
load_env

PI_USER="${PI_USER:-pi}"
PI_HOST="${PI_HOST:-}"
REMOTE_DIR="${REMOTE_DIR:-/home/$PI_USER/pi-gateway}"

[[ -n "$PI_HOST" ]] || die "PI_HOST required"

"$SCRIPT_DIR/render-config.sh"
"$SCRIPT_DIR/validate.sh"
"$SCRIPT_DIR/pre-deploy-check.sh"

PROFILES=()
[[ "${ENABLE_AUTOHEAL:-true}" == "true" ]] && PROFILES+=(--profile autoheal)
[[ "${ENABLE_CADDY:-true}" == "true" ]] && PROFILES+=(--profile caddy)
[[ "${ENABLE_DOZZLE:-true}" == "true" ]] && PROFILES+=(--profile dozzle)
[[ "${ENABLE_FORGEJO:-true}" == "true" ]] && PROFILES+=(--profile forgejo)
[[ "${ENABLE_SYNCTHING:-true}" == "true" ]] && PROFILES+=(--profile syncthing)
[[ "${ENABLE_REDIS:-true}" == "true" ]] && PROFILES+=(--profile redis)
[[ "${ENABLE_N8N:-true}" == "true" ]] && PROFILES+=(--profile n8n)
[[ "${ENABLE_NETALERTX:-true}" == "true" ]] && PROFILES+=(--profile netalert)
[[ "${ENABLE_CROWDSEC:-true}" == "true" ]] && PROFILES+=(--profile crowdsec)
[[ -n "${CLOUDFLARE_TUNNEL_TOKEN:-}" ]] && PROFILES+=(--profile cloudflare)
[[ "${ENABLE_WATCHTOWER:-false}" == "true" ]] && PROFILES+=(--profile watchtower)

log "Deploy -> $PI_USER@$PI_HOST:$REMOTE_DIR"

ssh -o ConnectTimeout=15 "$PI_USER@$PI_HOST" "mkdir -p '$REMOTE_DIR'"

rsync -avz --delete \
  --exclude '.git' \
  --exclude '.env' \
  --exclude 'data' \
  --filter 'protect data' \
  --filter 'protect data/**' \
  --filter 'protect config/homepage/logs' \
  --filter 'protect config/homepage/logs/**' \
  --exclude 'config/adguard/AdGuardHome.yaml' \
  --exclude 'config/homepage/services.yaml' \
  --exclude 'config/caddy/Caddyfile' \
  --exclude 'config/homepage/logs/**' \
  --exclude 'backups' \
  --exclude '*.bak' \
  --exclude 'legacy/' \
  "$PROJECT_DIR/" "$PI_USER@$PI_HOST:$REMOTE_DIR/"

scp "$PROJECT_DIR/.env" "$PI_USER@$PI_HOST:$REMOTE_DIR/.env"

"$SCRIPT_DIR/sync-rendered-configs.sh" || log "WARN: rendered config sync atlandi"

ssh "$PI_USER@$PI_HOST" "REMOTE_DIR='$REMOTE_DIR' TAILSCALE_AUTHKEY='${TAILSCALE_AUTHKEY:-}' TAILSCALE_HOSTNAME='${TAILSCALE_HOSTNAME:-pi-gateway}' STORAGE_TYPE='${STORAGE_TYPE:-ssd-root}' PI_INTERFACE='${PI_INTERFACE:-eth0}' bash -s" \
  < "$SCRIPT_DIR/../pi/bootstrap.sh"

DEPLOY_HOST="${PI_STATIC_IP:-$PI_HOST}"
sleep 5

PROFILE_ARGS="${PROFILES[*]}"
if [[ "${DEPLOY_SKIP_PULL:-false}" == "true" ]]; then
  log "docker compose up -d (pull atlandi — DEPLOY_SKIP_PULL=true)"
  ssh -o ConnectTimeout=20 "$PI_USER@$DEPLOY_HOST" "cd '$REMOTE_DIR/compose' && docker compose --env-file ../.env $PROFILE_ARGS up -d"
else
  ssh -o ConnectTimeout=20 "$PI_USER@$DEPLOY_HOST" "cd '$REMOTE_DIR/compose' && docker compose --env-file ../.env $PROFILE_ARGS pull && docker compose --env-file ../.env $PROFILE_ARGS up -d"
fi

sleep 12
ssh "$PI_USER@$DEPLOY_HOST" "REMOTE_DIR='$REMOTE_DIR' bash -s" < "$SCRIPT_DIR/../pi/post-deploy.sh"

ssh "$PI_USER@$DEPLOY_HOST" "REMOTE_DIR='$REMOTE_DIR' bash -s" < "$SCRIPT_DIR/../pi/smoke-test.sh"

log "Deploy complete"
DOMAIN="${LAN_DOMAIN:-home}"
log "  Gateway : https://gateway.${DOMAIN}"
log "  Status  : https://status.${DOMAIN}"
log "  Logs    : https://logs.${DOMAIN}"
log "  DNS     : https://dns.${DOMAIN}"
log "  Git     : https://git.${DOMAIN}"
log "  Sync    : https://sync.${DOMAIN}"
log "  n8n     : https://n8n.${DOMAIN}"
log "  UFW     : ${UFW_ADMIN_EXPOSURE:-caddy-only}"

if [[ "${NETWORK_MODE:-router-dns}" == "router-dns" ]]; then
  log "  ACTION  : Router DNS -> ${PI_STATIC_IP:-$PI_HOST}"
else
  log "  ACTION  : Router DHCP OFF; AdGuard DHCP active"
fi
