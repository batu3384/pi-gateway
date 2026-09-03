#!/usr/bin/env bash
# Prometheus TSDB bozulmasi: once WAL, sonra tum bloklar (gecmis metrik gider).
set -euo pipefail
REMOTE_DIR="${REMOTE_DIR:-/home/${USER}/pi-gateway}"
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=../lib/stack-health.sh
source "$SCRIPT_DIR/../lib/stack-health.sh"
# shellcheck source=../lib/env-file.sh
source "$SCRIPT_DIR/../lib/env-file.sh"
log() { echo "[repair-prometheus] $*"; }

repair_notify() {
  local mode="$1"
  local detail="${2:-}"
  [[ "${NOTIFY_REPAIR:-}" == "1" ]] || return 0
  read_remote_dotenv 2>/dev/null || true
  load_telegram_from_hermes 2>/dev/null || true
  # shellcheck source=../lib/notify.sh
  source "$SCRIPT_DIR/../lib/notify.sh"
  notify_enabled || return 0
  notify_prometheus_repair "$mode" "$detail" || true
}

PROM_DIR="${REMOTE_DIR}/data/prometheus"
LOCK="${PROMETHEUS_TSDB_REPAIR_LOCK:-/run/pi-gateway/prometheus-tsdb-repair.lock}"
COOLDOWN_SEC="${PROMETHEUS_TSDB_REPAIR_COOLDOWN_SEC:-3600}"
WAIT_SEC="${PROMETHEUS_TSDB_REPAIR_WAIT_SEC:-12}"

[[ "${ENABLE_MONITORING:-true}" == "true" ]] || { log "monitoring kapali"; exit 0; }
docker ps -a --format '{{.Names}}' | grep -qx prometheus || {
  log "prometheus container yok"
  exit 1
}

prometheus_ready() {
  docker ps --format '{{.Names}}' | grep -qx prometheus \
    && curl -fsS --max-time 3 http://127.0.0.1:9090/-/ready >/dev/null 2>&1
}

prometheus_tsdb_corrupt() {
  local logs
  logs="$(docker logs prometheus 2>&1 | tail -50)"
  echo "$logs" | grep -qE 'invalid checksum|opening storage failed' && return 0
  if ! prometheus_ready; then
    echo "$logs" | grep -q 'WAL truncation' && echo "$logs" | grep -q 'compaction failed'
    return $?
  fi
  return 1
}

prometheus_up() {
  (cd "${REMOTE_DIR}/compose" && docker compose --env-file ../.env --profile monitoring up -d prometheus) \
    || docker start prometheus
}

ensure_runtime_dir
if [[ -f "$LOCK" ]]; then
  last="$(cat "$LOCK" 2>/dev/null || echo 0)"
  now="$(date +%s)"
  if [[ "$last" =~ ^[0-9]+$ ]] && (( now - last < COOLDOWN_SEC )); then
    log "cooldown (${COOLDOWN_SEC}s) — atla"
    exit 1
  fi
fi

if prometheus_ready; then
  log "prometheus zaten healthy"
  exit 0
fi

if ! prometheus_tsdb_corrupt; then
  log "TSDB checksum hatasi yok — repair atlandi"
  exit 1
fi

runtime_write "$LOCK" "$(date +%s)"
docker stop prometheus >/dev/null 2>&1 || true

log "adim 1: wal + chunks_head temizligi"
rm -rf "${PROM_DIR}/wal" "${PROM_DIR}/chunks_head" "${PROM_DIR}/queries.active"
prometheus_up
sleep "$WAIT_SEC"
if prometheus_ready; then
  log "OK prometheus ready (wal repair)"
  repair_notify wal "Son saatlik ham scrape verisi sıfırlandı."
  exit 0
fi

if ! prometheus_tsdb_corrupt; then
  log "HATA: prometheus ayaga kalkmadi (TSDB disi)"
  exit 1
fi

bak="${PROM_DIR}/blocks.bak.$(date +%s)"
log "adim 2: bozuk bloklar yedekleniyor -> ${bak}"
mkdir -p "$bak"
shopt -s nullglob
for block in "${PROM_DIR}"/01*; do
  mv "$block" "$bak/"
done
shopt -u nullglob
rm -rf "${PROM_DIR}/wal" "${PROM_DIR}/chunks_head" "${PROM_DIR}/queries.active"
prometheus_up
sleep "$WAIT_SEC"
if prometheus_ready; then
  log "OK prometheus ready (blok reset — gecmis metrik yedek: ${bak})"
  repair_notify blocks "Yedek: ${bak}"
  exit 0
fi

log "HATA: prometheus ayaga kalkmadi"
exit 1
