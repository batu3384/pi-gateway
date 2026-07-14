#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=../lib/common.sh
source "$SCRIPT_DIR/../lib/common.sh"
load_env

require_cmd docker envsubst python3

[[ -f "$PROJECT_DIR/.env" ]] || die "Missing .env - cp .env.example .env"
[[ -n "${AGH_ADMIN_PASSWORD:-}" ]] || die "Set AGH_ADMIN_PASSWORD in .env"
[[ "${#AGH_ADMIN_PASSWORD}" -ge 12 ]] || die "AGH_ADMIN_PASSWORD must be at least 12 chars"

if [[ "${ENABLE_N8N:-true}" == "true" ]]; then
  [[ -n "${N8N_ENCRYPTION_KEY:-}" ]] || die "Set N8N_ENCRYPTION_KEY in .env (openssl rand -hex 24)"
  [[ "${#N8N_ENCRYPTION_KEY}" -ge 32 ]] || die "N8N_ENCRYPTION_KEY must be at least 32 chars"
fi

if [[ -z "${PI_STATIC_IP:-}" ]]; then
  log "WARN: PI_STATIC_IP not set. Run ./scripts/mac/discover-remote.sh when Pi is online"
fi

"$SCRIPT_DIR/render-config.sh"

docker compose -f "$PROJECT_DIR/compose/docker-compose.yml" --env-file "$PROJECT_DIR/.env" config -q
log "docker-compose validation: OK"

for f in \
  "$PROJECT_DIR/config/adguard/AdGuardHome.yaml" \
  "$PROJECT_DIR/config/unbound/unbound.conf"; do
  [[ -f "$f" ]] || die "Missing rendered file: $f"
done

log "Validation passed"
