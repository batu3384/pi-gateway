#!/usr/bin/env bash
# AdGuard bbolt (sessions.db / stats.db) bozulmasi — karantina + yeniden olustur.
set -euo pipefail
REMOTE_DIR="${REMOTE_DIR:-/home/${USER}/pi-gateway}"
DATA="${REMOTE_DIR}/data/adguard/work/data"
REPAIR_SKIP_RC=10
REPAIR_DEFERRED_RC=11
REPAIR_RESTART_ONLY_RC=12
log() { echo "[repair-adguard-bbolt] $*"; }

adguard_bbolt_broken() {
  local containers status health logs
  containers="$(docker ps -a --format '{{.Names}}' 2>/dev/null || true)"
  grep -qx adguard <<<"$containers" || return 1
  status="$(docker inspect adguard --format '{{.State.Status}}' 2>/dev/null || true)"
  health="$(docker inspect adguard --format '{{if .State.Health}}{{.State.Health.Status}}{{end}}' 2>/dev/null || true)"
  if [[ "$health" == "healthy" ]]; then
    return 1
  fi
  logs="$(docker logs adguard 2>&1 | tail -40 || true)"
  grep -qiE 'freelist|bbolt|panic.*sessions|panic.*stats' <<<"$logs" || return 1
  if [[ "$status" == "restarting" || "$status" == "exited" || "$health" == "unhealthy" ]]; then
    return 0
  fi
  return 2
}

if [[ "${1:-}" == "--self-check" ]]; then
  grep -q 'compose stop adguard' "$0" || exit 1
  grep -q 'REPAIR_SKIP_RC=10' "$0" || exit 1
  grep -q 'REPAIR_DEFERRED_RC=11' "$0" || exit 1
  grep -q 'REPAIR_RESTART_ONLY_RC=12' "$0" || exit 1
  log "self-check OK"
  exit 0
fi

[[ -d "$DATA" ]] || { log "HATA: $DATA yok"; exit 1; }
if adguard_bbolt_broken; then
  :
else
  broken_rc=$?
  if [[ "$broken_rc" -eq 2 ]]; then
    log "bbolt belirtisi var ancak AdGuard ara durumda — ertelendi"
    exit "$REPAIR_DEFERRED_RC"
  fi
  log "bbolt bozulma belirtisi yok — atlandi"
  exit "$REPAIR_SKIP_RC"
fi

if [[ -d "${REMOTE_DIR}/compose" ]]; then
  (cd "${REMOTE_DIR}/compose" && docker compose --env-file ../.env stop adguard) 2>/dev/null \
    || docker stop adguard >/dev/null 2>&1 || true
else
  docker stop adguard >/dev/null 2>&1 || true
fi
sleep 2

stamp="$(date +%Y%m%d-%H%M%S)"
qdir="${DATA}/quarantine-${stamp}"
mkdir -p "$qdir"
moved=0
for db in sessions.db stats.db; do
  if [[ -f "${DATA}/${db}" ]]; then
    mv "${DATA}/${db}" "${qdir}/${db}"
    log "karantina: ${db} -> ${qdir}/"
    moved=1
  fi
done
[[ "$moved" -eq 1 ]] || {
  log "WARN: db dosyasi yok — adguard yeniden baslatiliyor"
  if [[ -d "${REMOTE_DIR}/compose" ]]; then
    (cd "${REMOTE_DIR}/compose" && docker compose --env-file ../.env up -d adguard) || exit 1
  else
    docker start adguard >/dev/null || exit 1
  fi
  exit "$REPAIR_RESTART_ONLY_RC"
}

if [[ -d "${REMOTE_DIR}/compose" ]]; then
  (cd "${REMOTE_DIR}/compose" && docker compose --env-file ../.env up -d adguard) || exit 1
else
  docker start adguard >/dev/null || exit 1
fi

for _ in $(seq 1 30); do
  if docker inspect adguard --format '{{if .State.Health}}{{.State.Health.Status}}{{else}}none{{end}}' 2>/dev/null \
    | grep -qx healthy; then
    log "OK adguard healthy"
    exit 0
  fi
  sleep 2
done
log "WARN: adguard henuz healthy degil — log kontrol"
exit 1
