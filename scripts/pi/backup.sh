#!/usr/bin/env bash
# Config snapshot + optional restic (Docker). Must run as PI_USER with REMOTE_DIR set.
set -euo pipefail

# systemd Environment=REMOTE_DIR wins; never trust root's $USER alone
if [[ -z "${REMOTE_DIR:-}" ]]; then
  if [[ "$(id -u)" -eq 0 ]]; then
    echo "[backup] HATA: root + REMOTE_DIR bos — /home/root'a yazma. systemd User= + Environment=REMOTE_DIR kullan." >&2
    exit 1
  fi
  REMOTE_DIR="/home/${USER}/pi-gateway"
fi

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
