#!/usr/bin/env bash
# NetAlertX app.db — host (Hermes cron) okuma izni.
# Kök neden: container PGID=host grubu (.env NETALERTX_GID); chown 20211:host.
set -euo pipefail
REMOTE_DIR="${REMOTE_DIR:-/home/${USER}/pi-gateway}"
DATA_DIR="${NETALERTX_DATA:-${REMOTE_DIR}/data/netalertx}"
DB_DIR="${DATA_DIR}/db"
DB_FILE="${DB_DIR}/app.db"
_pi_u="${USER:-pi}"
_pi_g="$(id -g)"
_pi_gn="$(id -gn)"

[[ -d "$DB_DIR" ]] || exit 0

_run() {
  if "$@" 2>/dev/null; then return 0; fi
  sudo "$@"
}

# Eski yanlis ACL (dizinde x yok) temizle
if command -v setfacl >/dev/null 2>&1; then
  _run setfacl -b "$DB_DIR" 2>/dev/null || true
  for f in "$DB_DIR"/app.db "$DB_DIR"/app.db-wal "$DB_DIR"/app.db-shm; do
    [[ -e "$f" ]] && _run setfacl -b "$f" 2>/dev/null || true
  done
fi

_run chown "20211:${_pi_gn}" "$DB_DIR"
_run chmod 775 "$DB_DIR"

fix_one() {
  local p="$1"
  [[ -e "$p" ]] || return 0
  _run chown "20211:${_pi_gn}" "$p"
  _run chmod 660 "$p"
}

for f in "$DB_DIR"/app.db "$DB_DIR"/app.db-wal "$DB_DIR"/app.db-shm; do
  fix_one "$f"
done

[[ -r "$DB_FILE" ]] || {
  echo "[ensure-netalert-db] HATA: app.db okunamiyor ($DB_FILE) — NETALERTX_GID=${_pi_g} .env + netalertx recreate" >&2
  exit 1
}
