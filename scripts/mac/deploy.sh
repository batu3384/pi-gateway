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
[[ "${ENABLE_AUTOHEAL:-false}" == "true" ]] && PROFILES+=(--profile autoheal)
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
  --exclude 'data.sd-degraded.bak*' \
  --filter 'protect data' \
  --filter 'protect data/**' \
  --filter 'protect data.sd-degraded.bak*' \
  --filter 'protect data.sd-degraded.bak*/**' \
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

ssh "$PI_USER@$PI_HOST" "REMOTE_DIR='$REMOTE_DIR' TAILSCALE_AUTHKEY='${TAILSCALE_AUTHKEY:-}' TAILSCALE_HOSTNAME='${TAILSCALE_HOSTNAME:-pi-gateway}' STORAGE_TYPE='${STORAGE_TYPE:-hybrid}' PI_INTERFACE='${PI_INTERFACE:-eth0}' bash -s" \
  < "$SCRIPT_DIR/../pi/bootstrap.sh"

DEPLOY_HOST="${PI_STATIC_IP:-$PI_HOST}"

# Deploy is non-interactive: SSH key auth required (password prompts hang/fail).
wait_ssh() {
  local host="$1" tries="${2:-24}" i
  for ((i = 1; i <= tries; i++)); do
    if ssh -o ConnectTimeout=5 -o BatchMode=yes -o StrictHostKeyChecking=accept-new \
      "$PI_USER@$host" 'true' 2>/dev/null; then
      log "SSH ready: $PI_USER@$host (attempt $i)"
      return 0
    fi
    sleep 5
  done
  die "SSH failed after dhcpcd/bootstrap: $PI_USER@$host — need working SSH key (ssh-copy-id); password-only auth not supported for deploy"
}

log "Waiting for SSH on deploy host ($DEPLOY_HOST) after bootstrap..."
wait_ssh "$DEPLOY_HOST"

PROFILE_ARGS="${PROFILES[*]}"
# SSD yok / degraded / stale: core-dns only (ephemeral app data yazma)
COMPOSE_MODE="$(ssh -o ConnectTimeout=20 "$PI_USER@$DEPLOY_HOST" \
  "REMOTE_DIR='$REMOTE_DIR' bash -s" <<'REMOTE_EOF'
set -euo pipefail
# shellcheck source=/dev/null
[[ -f "$REMOTE_DIR/.env" ]] && set -a && source "$REMOTE_DIR/.env" && set +a
# shellcheck source=/dev/null
source "$REMOTE_DIR/scripts/lib/stack-health.sh"
if ! needs_ssd_storage; then
  echo full
  exit 0
fi
if storage_degraded || ! ssd_mount_healthy; then
  echo core-dns
else
  echo full
fi
REMOTE_EOF
)" || COMPOSE_MODE="full"
COMPOSE_MODE="$(echo "$COMPOSE_MODE" | tr -d '\r' | tail -1)"

if [[ "$COMPOSE_MODE" == "core-dns" ]]; then
  log "SSD yok/degraded — compose core-dns (unbound+adguard+caddy/homepage)"
  if [[ "${DEPLOY_SKIP_PULL:-false}" != "true" ]]; then
    ssh -o ConnectTimeout=20 "$PI_USER@$DEPLOY_HOST" \
      "cd '$REMOTE_DIR/compose' && docker compose --env-file ../.env --profile caddy pull unbound adguard homepage caddy" \
      || log "WARN: core-dns pull kismi"
  fi
  ssh -o ConnectTimeout=20 "$PI_USER@$DEPLOY_HOST" \
    "REMOTE_DIR='$REMOTE_DIR' COMPOSE_RECOVER_MODE=core-dns bash '$REMOTE_DIR/scripts/pi/recover-compose-up.sh'"
else
  if [[ "${DEPLOY_SKIP_PULL:-false}" == "true" ]]; then
    log "docker compose up -d (pull skipped — DEPLOY_SKIP_PULL=true)"
    ssh -o ConnectTimeout=20 "$PI_USER@$DEPLOY_HOST" "cd '$REMOTE_DIR/compose' && docker compose --env-file ../.env $PROFILE_ARGS up -d"
  else
    ssh -o ConnectTimeout=20 "$PI_USER@$DEPLOY_HOST" "cd '$REMOTE_DIR/compose' && docker compose --env-file ../.env $PROFILE_ARGS pull && docker compose --env-file ../.env $PROFILE_ARGS up -d"
  fi
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
