#!/usr/bin/env bash
# AdGuard stats → Prometheus textfile (health timer / export-gateway-state)
set -euo pipefail
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REMOTE_DIR="${REMOTE_DIR:-/home/${USER}/pi-gateway}"
METRICS_DIR="${PI_GATEWAY_METRICS_DIR:-/var/lib/pi-gateway/metrics}"
OUT="${METRICS_DIR}/pi_gateway_adguard.prom"
METRICS_PY="${SCRIPT_DIR}/../lib/adguard-metrics.py"
[[ -f "$METRICS_PY" ]] || METRICS_PY="${REMOTE_DIR}/scripts/lib/adguard-metrics.py"

if [[ "${1:-}" == "--self-check" ]]; then
  python3 "$METRICS_PY" --self-check
  exit 0
fi

# shellcheck source=../lib/env-file.sh
source "$SCRIPT_DIR/../lib/env-file.sh"
read_remote_dotenv || true
# shellcheck source=../lib/adguard-api.sh
source "$SCRIPT_DIR/../lib/adguard-api.sh"

ADGUARD_WEB_PORT="${ADGUARD_WEB_PORT:-8080}"
AGH_ADMIN_USER="${AGH_ADMIN_USER:-admin}"
AGH_ADMIN_PASSWORD="${AGH_ADMIN_PASSWORD:-}"
BASE="http://127.0.0.1:${ADGUARD_WEB_PORT}"

STATS_FILE="$(mktemp)"
STATUS_FILE="$(mktemp)"
PROM_TMP="$(mktemp)"
COOKIE=""
cleanup() {
  rm -f "$STATS_FILE" "$STATUS_FILE" "$PROM_TMP" "$COOKIE"
}
trap cleanup EXIT
echo '{}' >"$STATS_FILE"
echo '{}' >"$STATUS_FILE"

write_prom() {
  local up="$1"
  python3 "$METRICS_PY" "$PROM_TMP" "$up" "$STATS_FILE" "$STATUS_FILE"
  if [[ "$(id -u)" -eq 0 ]]; then
    mkdir -p "$METRICS_DIR"
    install -m 644 "$PROM_TMP" "$OUT"
    chown "${USER}:${USER}" "$OUT" 2>/dev/null || true
  else
    sudo mkdir -p "$METRICS_DIR"
    sudo install -m 644 "$PROM_TMP" "$OUT"
    sudo chown "${USER}:${USER}" "$OUT" 2>/dev/null || true
  fi
}

if [[ -z "$AGH_ADMIN_PASSWORD" ]]; then
  write_prom 0
  echo "[export-adguard] WARN AGH_ADMIN_PASSWORD bos"
  exit 0
fi

COOKIE="$(mktemp)"
up=0
if agh_login "$BASE" "$COOKIE" "$AGH_ADMIN_USER" "$AGH_ADMIN_PASSWORD" 3; then
  # ponytail: status JSON argv'ye sigmaz (ARG_MAX) — dosyadan oku
  if curl -fsS --max-time 10 -b "$COOKIE" "${BASE}/control/stats" -o "$STATS_FILE" \
    && curl -fsS --max-time 10 -b "$COOKIE" "${BASE}/control/filtering/status" -o "$STATUS_FILE"; then
    up=1
  fi
fi
write_prom "$up"
echo "[export-adguard] OK up=${up} ${OUT}"
