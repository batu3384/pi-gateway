#!/usr/bin/env bash
# VictoriaMetrics + Grafana (472) data dir ownership
set -euo pipefail
REMOTE_DIR="${REMOTE_DIR:-/home/${USER}/pi-gateway}"
log() { echo "[monitoring-data] $*"; }

[[ "${ENABLE_MONITORING:-true}" == "true" ]] || { log "atlandi (ENABLE_MONITORING=false)"; exit 0; }

vm_dir="${REMOTE_DIR}/data/victoriametrics"
graf_dir="${REMOTE_DIR}/data/grafana"
graf_uid="${GRAFANA_UID:-472}"
graf_gid="${GRAFANA_GID:-472}"
mkdir -p "$vm_dir" "$graf_dir"
if [[ "$(id -u)" -eq 0 ]]; then
  chown -R "${graf_uid}:${graf_gid}" "$graf_dir"
else
  sudo chown -R "${graf_uid}:${graf_gid}" "$graf_dir"
fi
log "OK victoriametrics=${vm_dir} grafana=${graf_uid}:${graf_gid}"
