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
STAGING="$REMOTE_DIR/backups/.staging-$STAMP-$$"
mkdir -p "$STAGING"
trap 'rm -rf "$STAGING"' EXIT
cp "$REMOTE_DIR/compose/docker-compose.yml" "$STAGING/"
cp -r "$REMOTE_DIR/config" "$STAGING/"
# .env sifreleri duz metin yedeklenmez — anahtar listesi yeterli (restic sifreli repo)
if [[ -f "$REMOTE_DIR/.env" ]]; then
  grep -E '^[A-Z][A-Z0-9_]*=' "$REMOTE_DIR/.env" | cut -d= -f1 | sort > "$STAGING/env-keys.txt"
fi
mv "$STAGING" "$DEST"
# Config snapshot retention (restic forget ayri)
KEEP="${CONFIG_BACKUP_KEEP:-14}"
if (( KEEP > 0 )); then
  while IFS= read -r old; do
    [[ -n "$old" && -d "$old" ]] && rm -rf "$old"
  done < <(find "$REMOTE_DIR/backups" -maxdepth 1 -type d -name '20*' 2>/dev/null | sort | head -n "-$KEEP")
fi
echo "Backup saved: $DEST (secrets excluded; use restic for encrypted data)"
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=../lib/notify.sh
source "$SCRIPT_DIR/../lib/notify.sh"
_PG_ENV_LIB="${SCRIPT_DIR:-$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)}/../lib/env-file.sh"
PG_SCRIPT_NAME="$(basename "$0")"
# shellcheck source=../lib/env-file.sh
source "${_PG_ENV_LIB:?}"
read_remote_dotenv || { echo "[${PG_SCRIPT_NAME:-script}] HATA: .env dotenv parser hatasi" >&2; exit 1; }
restic_failed=0
if [[ "${ENABLE_RESTIC:-true}" == "true" ]] && [[ ! -x "$REMOTE_DIR/scripts/pi/restic-backup.sh" ]]; then
  echo "[backup] HATA: restic-backup.sh yok veya executable degil" >&2
  notify_backup_fail "restic-backup.sh missing"
  exit 1
fi
if [[ -x "$REMOTE_DIR/scripts/pi/restic-backup.sh" ]]; then
  export REMOTE_DIR
  if restic_out="$(bash "$REMOTE_DIR/scripts/pi/restic-backup.sh" 2>&1)"; then
    printf '%s\n' "$restic_out"
    # Degraded skip = basari (yaniltici fail notify yok)
    if printf '%s\n' "$restic_out" | grep -qE 'SSD mount yok veya degraded — yedek atlandi|yedek atlandi \(ENABLE_RESTIC'; then
      :
    elif printf '%s\n' "$restic_out" | grep -qE 'SSD mount yok|degraded' \
      && ! printf '%s\n' "$restic_out" | grep -q 'ENABLE_RESTIC=false'; then
      notify_backup_fail "$(printf '%s\n' "$restic_out" | tail -3 | tr '\n' ' ')"
    fi
  else
    printf '%s\n' "$restic_out"
    echo "[backup] WARN: restic hata"
    notify_backup_fail "$(printf '%s\n' "$restic_out" | tail -5 | tr '\n' ' ')"
    restic_failed=1
  fi
fi
exit "$restic_failed"
