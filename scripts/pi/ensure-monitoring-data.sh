#!/usr/bin/env bash
# Prometheus (65534) + Grafana (472) data dir ownership
set -euo pipefail
REMOTE_DIR="${REMOTE_DIR:-/home/${USER}/pi-gateway}"
log() { echo "[monitoring-data] $*"; }

[[ "${ENABLE_MONITORING:-true}" == "true" ]] || { log "atlandi (ENABLE_MONITORING=false)"; exit 0; }

prom_dir="${REMOTE_DIR}/data/prometheus"
graf_dir="${REMOTE_DIR}/data/grafana"
prom_uid="${PROMETHEUS_UID:-1000}"
prom_gid="${PROMETHEUS_GID:-1000}"
graf_uid="${GRAFANA_UID:-472}"
graf_gid="${GRAFANA_GID:-472}"
mkdir -p "$prom_dir" "$graf_dir"
if [[ "$(id -u)" -eq 0 ]]; then
  chown -R "${prom_uid}:${prom_gid}" "$prom_dir"
  chown -R "${graf_uid}:${graf_gid}" "$graf_dir"
else
  sudo chown -R "${prom_uid}:${prom_gid}" "$prom_dir"
  sudo chown -R "${graf_uid}:${graf_gid}" "$graf_dir"
fi
log "OK prometheus=${prom_uid}:${prom_gid} grafana=${graf_uid}:${graf_gid}"
