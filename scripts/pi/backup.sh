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

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=../lib/notify.sh
source "$SCRIPT_DIR/../lib/notify.sh"
# shellcheck source=/dev/null
[[ -f "$REMOTE_DIR/.env" ]] && set -a && source "$REMOTE_DIR/.env" && set +a

if [[ -x "$REMOTE_DIR/scripts/pi/restic-backup.sh" ]]; then
  export REMOTE_DIR
  if restic_out="$(bash "$REMOTE_DIR/scripts/pi/restic-backup.sh" 2>&1)"; then
    printf '%s\n' "$restic_out"
    if printf '%s\n' "$restic_out" | grep -qE 'SSD mount yok|degraded|yedek atlandi'; then
      if ! printf '%s\n' "$restic_out" | grep -q 'ENABLE_RESTIC=false'; then
        notify_backup_fail "$(printf '%s\n' "$restic_out" | tail -3 | tr '\n' ' ')"
      fi
    fi
  else
    printf '%s\n' "$restic_out"
    echo "[backup] WARN: restic hata"
    notify_backup_fail "$(printf '%s\n' "$restic_out" | tail -5 | tr '\n' ' ')"
  fi
fi
