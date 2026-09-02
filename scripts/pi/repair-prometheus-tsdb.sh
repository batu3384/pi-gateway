#!/usr/bin/env bash
# Prometheus TSDB bozulmasi: once WAL, sonra tum bloklar (gecmis metrik gider).
set -euo pipefail
REMOTE_DIR="${REMOTE_DIR:-/home/${USER}/pi-gateway}"
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=../lib/stack-health.sh
source "$SCRIPT_DIR/../lib/stack-health.sh"
log() { echo "[repair-prometheus] $*"; }

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
  docker logs prometheus 2>&1 | tail -30 | grep -qE 'invalid checksum|opening storage failed'
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
  exit 0
fi

log "HATA: prometheus ayaga kalkmadi"
exit 1
