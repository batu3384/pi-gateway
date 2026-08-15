#!/usr/bin/env bash
# Staged compose pull/up: DNS once, wait, edge, then rest (canary update)
set -euo pipefail
REMOTE_DIR="${REMOTE_DIR:-/home/${USER}/pi-gateway}"
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=../lib/env-file.sh
source "$SCRIPT_DIR/../lib/env-file.sh"
read_remote_dotenv || { echo "[canary-compose] HATA: .env dotenv parser hatasi" >&2; exit 1; }
# shellcheck source=../lib/compose-profiles.sh
source "$SCRIPT_DIR/../lib/compose-profiles.sh"
# shellcheck source=../lib/stack-health.sh
source "$SCRIPT_DIR/../lib/stack-health.sh"

log() { echo "[canary-compose] $*"; }
DNS_WAIT_SEC="${CANARY_DNS_WAIT_SEC:-45}"
SKIP_PULL="${CANARY_SKIP_PULL:-${DEPLOY_SKIP_PULL:-false}}"
cd "$REMOTE_DIR/compose"
mapfile -t profiles < <(compose_profiles)

compose() {
  docker compose --env-file ../.env "${profiles[@]}" "$@"
}

wait_container_healthy() {
  local name="$1" tries="${2:-45}" i status
  for ((i = 1; i <= tries; i++)); do
    status="$(docker inspect --format '{{if .State.Health}}{{.State.Health.Status}}{{else}}{{.State.Status}}{{end}}' "$name" 2>/dev/null || echo missing)"
    case "$status" in
      healthy|running) return 0 ;;
      unhealthy|exited|missing) ;;
    esac
    sleep 2
  done
  log "WARN: $name hazir degil (status=$status)"
  return 1
}

wait_dns_core() {
  local ip="${PI_STATIC_IP:-127.0.0.1}"
  if [[ -x "$SCRIPT_DIR/wait-adguard-dns.sh" ]]; then
    REMOTE_DIR="$REMOTE_DIR" bash "$SCRIPT_DIR/wait-adguard-dns.sh" || return 1
  fi
  if command -v dig >/dev/null 2>&1; then
    dig +time=3 +tries=2 "@${ip}" cloudflare.com A +short | grep -qE '^[0-9.]+$' || return 1
  fi
  return 0
}

pull_if() {
  [[ "$SKIP_PULL" == "true" ]] && return 0
  compose pull "$@"
}

phase_dns() {
  log "phase 1/3: DNS (unbound + adguard)"
  pull_if unbound adguard
  compose up -d unbound adguard
  wait_container_healthy unbound 40 || true
  wait_container_healthy adguard 90 || true
  wait_dns_core || { log "HATA: DNS core hazir degil"; return 1; }
  log "DNS OK — ${DNS_WAIT_SEC}s bekleme"
  sleep "$DNS_WAIT_SEC"
}

phase_edge() {
  log "phase 2/3: edge (gateway-state + homepage + caddy)"
  local edge=(gateway-state homepage caddy)
  pull_if "${edge[@]}"
  compose up -d "${edge[@]}"
  wait_container_healthy gateway-state 20 || true
}

phase_rest() {
  log "phase 3/3: kalan servisler"
  if [[ "$SKIP_PULL" == "true" ]]; then
    compose up -d --remove-orphans
    return 0
  fi
  pull_if
  compose up -d --remove-orphans
}

if needs_ssd_storage && ! ssd_mount_healthy 2>/dev/null; then
  if storage_degraded || dns_degraded_on_ssd_loss; then
    log "SSD degraded — core-dns modu"
    COMPOSE_RECOVER_MODE=core-dns REMOTE_DIR="$REMOTE_DIR" bash "$SCRIPT_DIR/recover-compose-up.sh"
    exit 0
  fi
  log "HATA: SSD bekleniyor ama mount yok"
  exit 1
fi

phase_dns
phase_edge
phase_rest
log "Tamamlandi"
