#!/usr/bin/env bash
# Post-deploy integration asserts (Path A — Guven)
set -euo pipefail
REMOTE_DIR="${REMOTE_DIR:-/home/${USER}/pi-gateway}"
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
fail=0
note_fail() {
  echo "[post-deploy-integration] FAIL $1" >&2
  fail=1
}
ok() { echo "[post-deploy-integration] OK $1"; }

if [[ -x "$SCRIPT_DIR/export-gateway-state.sh" ]]; then
  if REMOTE_DIR="$REMOTE_DIR" bash "$SCRIPT_DIR/export-gateway-state.sh"; then
    ok "export-gateway-state"
  else
    note_fail "export-gateway-state"
  fi
else
  note_fail "export-gateway-state-missing"
fi

if [[ -f /var/lib/pi-gateway/metrics/pi_gateway.prom ]]; then
  ok "metrics-file"
else
  note_fail "metrics-file-missing"
fi
if [[ -f /var/lib/pi-gateway/metrics/pi_gateway_adguard.prom ]]; then
  ok "adguard-metrics-file"
else
  note_fail "adguard-metrics-file-missing"
fi
if [[ -f /var/lib/pi-gateway/metrics/pi_gateway_ibb.prom ]]; then
  ok "ibb-metrics-file"
else
  echo "[post-deploy-integration] WARN ibb-metrics-file-missing (timer henüz koşmamış olabilir)"
fi

if [[ -f /var/lib/pi-gateway/state.json ]]; then
  ok "state-json"
else
  note_fail "state-json-missing"
fi

# shellcheck source=../lib/env-file.sh
source "$SCRIPT_DIR/../lib/env-file.sh"
read_remote_dotenv || { note_fail "dotenv"; exit 1; }
# shellcheck source=../lib/stack-health.sh
source "$SCRIPT_DIR/../lib/stack-health.sh"

if [[ "${ENABLE_DOCKER_SSD:-false}" == "true" ]] && ! storage_degraded; then
  if docker_ssd_root_ok; then
    ok "docker-ssd-root"
  else
    note_fail "docker-ssd-root"
  fi
fi

if needs_ssd_storage && ! storage_degraded; then
  if declare -F ssd_mount_healthy >/dev/null 2>&1 && ssd_mount_healthy; then
    ok "ssd-mount-healthy"
  else
    note_fail "ssd-mount-unhealthy"
  fi
fi

[[ "$fail" -eq 0 ]] || exit 1
echo "[post-deploy-integration] Tum kontroller gecti"
