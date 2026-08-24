#!/usr/bin/env bash
# Prometheus + Grafana + node-exporter (monitoring profile).
set -euo pipefail
REMOTE_DIR="${REMOTE_DIR:-/home/${USER}/pi-gateway}"
COMPOSE="${REMOTE_DIR}/compose"
[[ -d "$COMPOSE" ]] || { echo "[monitoring] HATA: compose yok"; exit 1; }
cd "$COMPOSE"
exec docker compose --env-file ../.env --profile monitoring up -d prometheus grafana node-exporter
