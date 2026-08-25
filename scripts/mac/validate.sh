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

# TLS fail-closed (LAN partial trust). Escape: WEAK_TLS_OK=yes
if [[ "${ENABLE_TLS:-true}" != "true" ]]; then
  if [[ "${WEAK_TLS_OK:-}" == "yes" ]]; then
    log "WARN: ENABLE_TLS=false (WEAK_TLS_OK=yes) — HTTP panel passwords"
  else
    die "ENABLE_TLS=true required (or WEAK_TLS_OK=yes). Run: make tls-certs"
  fi
fi

if [[ "${ENABLE_TLS:-true}" == "true" && "${ENABLE_N8N:-true}" == "true" ]]; then
  if [[ "${N8N_SECURE_COOKIE:-true}" != "true" ]]; then
    die "N8N_SECURE_COOKIE=true required when ENABLE_TLS=true"
  fi
fi

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
chmod +x "$SCRIPT_DIR/validate-public-repo.sh" 2>/dev/null || true
"$SCRIPT_DIR/validate-public-repo.sh"
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
chmod +x "$SCRIPT_DIR/test-smoke-contract.sh" 2>/dev/null || true
if [[ -f "$SCRIPT_DIR/test-smoke-contract.sh" ]]; then
  "$SCRIPT_DIR/test-smoke-contract.sh"
fi
chmod +x "$SCRIPT_DIR/test-dns-blocking-contract.sh" 2>/dev/null || true
if [[ -f "$SCRIPT_DIR/test-dns-blocking-contract.sh" ]]; then
  "$SCRIPT_DIR/test-dns-blocking-contract.sh"
fi
chmod +x "$SCRIPT_DIR/test-adversarial-fixes.sh" 2>/dev/null || true
if [[ -f "$SCRIPT_DIR/test-adversarial-fixes.sh" ]]; then
  "$SCRIPT_DIR/test-adversarial-fixes.sh"
fi
chmod +x "$SCRIPT_DIR/test-hermes-bulletins.sh" "$PROJECT_DIR/scripts/pi/fx-quote.sh" 2>/dev/null || true
if [[ -f "$SCRIPT_DIR/test-hermes-bulletins.sh" ]]; then
  "$SCRIPT_DIR/test-hermes-bulletins.sh"
fi
chmod +x "$SCRIPT_DIR/test-ssd-fsm.sh" 2>/dev/null || true
if [[ -f "$SCRIPT_DIR/test-ssd-fsm.sh" ]]; then
  "$SCRIPT_DIR/test-ssd-fsm.sh"
fi
chmod +x "$SCRIPT_DIR/test-roadmap-path-a.sh" 2>/dev/null || true
if [[ -f "$SCRIPT_DIR/test-roadmap-path-a.sh" ]]; then
  "$SCRIPT_DIR/test-roadmap-path-a.sh"
fi
chmod +x "$SCRIPT_DIR/test-homepage-unified-login.sh" 2>/dev/null || true
if [[ -f "$SCRIPT_DIR/test-homepage-unified-login.sh" ]]; then
  "$SCRIPT_DIR/test-homepage-unified-login.sh"
fi
chmod +x "$SCRIPT_DIR/test-path-b-visibility.sh" 2>/dev/null || true
if [[ -f "$SCRIPT_DIR/test-path-b-visibility.sh" ]]; then
  "$SCRIPT_DIR/test-path-b-visibility.sh"
fi
chmod +x "$SCRIPT_DIR/test-ssd-chaos.sh" 2>/dev/null || true
if [[ -f "$SCRIPT_DIR/test-ssd-chaos.sh" ]]; then
  "$SCRIPT_DIR/test-ssd-chaos.sh"
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
  "$PROJECT_DIR/config/adguard/user-rules.txt" \
  "$PROJECT_DIR/config/adguard/filter-lists.json" \
  "$PROJECT_DIR/config/unbound/unbound.conf"; do
  [[ -f "$f" ]] || die "Missing rendered file: $f"
done
grep -q '__FILTER_LISTS_YAML__' "$PROJECT_DIR/config/adguard/AdGuardHome.yaml.template" \
  || die "AdGuard template __FILTER_LISTS_YAML__ marker yok"
grep -q '__FILTER_LISTS_YAML__' "$PROJECT_DIR/config/adguard/AdGuardHome.yaml" \
  && die "Rendered AdGuardHome.yaml filtre placeholder kaldi — make render"
grep -q '\-\-fix-light' "$PROJECT_DIR/scripts/pi/ensure-adguard-blocking.sh" \
  || die "ensure-adguard-blocking --fix-light yok"
grep -q '\-\-fix-light' "$PROJECT_DIR/scripts/pi/health-check.sh" \
  || die "health-check adguard light heal yok"

log "Validation passed"
