#!/usr/bin/env bash
# NetAlertX app.db — host (batu/Hermes cron) okuma izni. Container restart sonrasi WAL/SHM 20211:20211 olur.
set -euo pipefail
REMOTE_DIR="${REMOTE_DIR:-/home/${USER}/pi-gateway}"
DATA_DIR="${NETALERTX_DATA:-${REMOTE_DIR}/data/netalertx}"
DB_DIR="${DATA_DIR}/db"
_pi_u="${USER:-pi}"

[[ -d "$DB_DIR" ]] || exit 0

fix_one() {
  local p="$1"
  [[ -e "$p" ]] || return 0
  chown 20211:"$_pi_u" "$p" 2>/dev/null || sudo chown 20211:"$_pi_u" "$p"
  chmod 660 "$p" 2>/dev/null || sudo chmod 660 "$p"
}

chown 20211:"$_pi_u" "$DB_DIR" 2>/dev/null || sudo chown 20211:"$_pi_u" "$DB_DIR"
chmod 775 "$DB_DIR" 2>/dev/null || sudo chmod 775 "$DB_DIR"
for f in "$DB_DIR"/app.db "$DB_DIR"/app.db-wal "$DB_DIR"/app.db-shm; do
  fix_one "$f"
done
