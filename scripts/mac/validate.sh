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

chmod +x "$SCRIPT_DIR/validate-stack-health.sh" 2>/dev/null || true
"$SCRIPT_DIR/validate-stack-health.sh"
chmod +x "$SCRIPT_DIR/validate-ssd-root-contract.sh" 2>/dev/null || true
if [[ -f "$SCRIPT_DIR/validate-ssd-root-contract.sh" ]]; then
  "$SCRIPT_DIR/validate-ssd-root-contract.sh"
fi
chmod +x "$SCRIPT_DIR/validate-recovery-contract.sh" 2>/dev/null || true
if [[ -f "$SCRIPT_DIR/validate-recovery-contract.sh" ]]; then
  "$SCRIPT_DIR/validate-recovery-contract.sh"
fi
chmod +x "$SCRIPT_DIR/validate-hybrid-contract.sh" 2>/dev/null || true
if [[ -f "$SCRIPT_DIR/validate-hybrid-contract.sh" ]]; then
  "$SCRIPT_DIR/validate-hybrid-contract.sh"
fi

# Mac: docker compose plugin yoksa docker-compose (v2 standalone / OrbStack)
compose_config() {
  local yml="$PROJECT_DIR/compose/docker-compose.yml"
  local envf="$PROJECT_DIR/.env"
  if docker compose version >/dev/null 2>&1; then
    docker compose -f "$yml" --env-file "$envf" config -q
  elif command -v docker-compose >/dev/null 2>&1; then
    docker-compose -f "$yml" --env-file "$envf" config -q
  else
    die "docker compose / docker-compose yok"
  fi
}
compose_config
log "docker-compose validation: OK"

for f in \
  "$PROJECT_DIR/config/adguard/AdGuardHome.yaml" \
  "$PROJECT_DIR/config/unbound/unbound.conf"; do
  [[ -f "$f" ]] || die "Missing rendered file: $f"
done

log "Validation passed"
