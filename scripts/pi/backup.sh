#!/usr/bin/env bash
set -euo pipefail

REMOTE_DIR="${REMOTE_DIR:-/home/${USER}/pi-gateway}"
STAMP="$(date +%Y%m%d-%H%M%S)"
DEST="$REMOTE_DIR/backups/$STAMP"
mkdir -p "$DEST"

cp "$REMOTE_DIR/compose/docker-compose.yml" "$DEST/" 2>/dev/null || true
cp -r "$REMOTE_DIR/config" "$DEST/" 2>/dev/null || true

# .env sifreleri duz metin yedeklenmez — anahtar listesi yeterli (restic sifreli repo)
if [[ -f "$REMOTE_DIR/.env" ]]; then
  grep -E '^[A-Z][A-Z0-9_]*=' "$REMOTE_DIR/.env" | cut -d= -f1 | sort > "$DEST/env-keys.txt"
fi

echo "Backup saved: $DEST (secrets excluded; use restic for encrypted data)"

if [[ -x "$REMOTE_DIR/scripts/pi/restic-backup.sh" ]]; then
  export REMOTE_DIR
  bash "$REMOTE_DIR/scripts/pi/restic-backup.sh" || \
    echo "[backup] WARN: restic atlandi veya hata"
fi
