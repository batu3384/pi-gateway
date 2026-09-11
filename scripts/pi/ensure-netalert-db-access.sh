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

_db_integrity_ok() {
  local p="$1"
  [[ -f "$p" ]] || return 0
  python3 - "$p" <<'PY'
import sqlite3
import sys

path = sys.argv[1]
try:
    con = sqlite3.connect(f"file:{path}?mode=ro", uri=True)
    row = con.execute("PRAGMA integrity_check").fetchone()
    con.close()
except sqlite3.Error:
    raise SystemExit(1)
raise SystemExit(0 if row and row[0] == "ok" else 1)
PY
}

_quarantine_corrupt_db() {
  local stamp dest
  stamp="$(date -u +%Y%m%dT%H%M%SZ)"
  dest="${DB_DIR}/corrupt-${stamp}"
  echo "[ensure-netalert-db] app.db bozuk — karantina ${dest}" >&2
  docker stop netalertx >/dev/null 2>&1 || true
  _run mkdir -p "$dest"
  for f in "$DB_DIR"/app.db "$DB_DIR"/app.db-wal "$DB_DIR"/app.db-shm; do
    [[ -e "$f" ]] || continue
    _run mv "$f" "$dest/"
  done
}

if [[ -f "$DB_FILE" ]]; then
  _running="$(docker inspect -f '{{.State.Running}}' netalertx 2>/dev/null || echo false)"
  if [[ "$_running" != "true" ]]; then
    if ! _db_integrity_ok "$DB_FILE"; then
      _quarantine_corrupt_db
    fi
  fi
else
  _running="false"
fi

# Canlı sqlite chown/chmod = malformed (WAL). Yalnız dururken.
if [[ "${_running}" != "true" ]]; then
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
fi

docker start netalertx >/dev/null 2>&1 || true

[[ -f "$DB_FILE" ]] || {
  echo "[ensure-netalert-db] app.db yok — NetAlertX olusturacak"
  exit 0
}
[[ -r "$DB_FILE" ]] || {
  echo "[ensure-netalert-db] HATA: app.db okunamiyor ($DB_FILE) — NETALERTX_GID=${_pi_g} .env + netalertx recreate" >&2
  exit 1
}
