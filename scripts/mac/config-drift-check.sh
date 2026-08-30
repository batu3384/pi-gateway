#!/usr/bin/env bash
# Mac: rendered config hash vs Pi (deploy drift detection)
set -euo pipefail
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=../lib/common.sh
source "$SCRIPT_DIR/../lib/common.sh"
load_env

PI_USER="${PI_USER:-pi}"
PI_HOST="${PI_STATIC_IP:-${PI_HOST:-}}"
REMOTE_DIR="${REMOTE_DIR:-/home/$PI_USER/pi-gateway}"
PROJECT_DIR="${PROJECT_DIR:-$(cd "$SCRIPT_DIR/../.." && pwd)}"

die() { echo "[config-drift] HATA: $*" >&2; exit 1; }
log() { echo "[config-drift] $*"; }
ok() { echo "[config-drift] OK: $*"; }

[[ -n "$PI_HOST" ]] || die "PI_STATIC_IP gerekli"

canonical_hash() {
  python3 - "$1" <<'PY' | sha256sum | awk '{print $1}'
import re
import sys

text = open(sys.argv[1], encoding="utf-8").read()
text = re.sub(r"\$2[aby]\$\d{2}\$[./A-Za-z0-9]+", "<BCRYPT>", text)
print(text.rstrip())
PY
}

canonical_hash_remote() {
  local path="$1"
  local text
  if ! text="$(ssh -o ConnectTimeout=15 -o BatchMode=yes "$PI_USER@$PI_HOST" \
    python3 - "$path" <<'PY'
import re
import sys

text = open(sys.argv[1], encoding="utf-8").read()
text = re.sub(r"\$2[aby]\$\d{2}\$[./A-Za-z0-9]+", "<BCRYPT>", text)
print(text.rstrip())
PY
  )"; then
    return 1
  fi
  printf '%s\n' "$text" | sha256sum | awk '{print $1}'
}

PATHS=(
  "config/adguard/AdGuardHome.yaml"
  "config/unbound/unbound.conf"
  "config/caddy/Caddyfile"
  "compose/docker-compose.yml"
)

fail=0
for rel in "${PATHS[@]}"; do
  local_f="$PROJECT_DIR/$rel"
  [[ -f "$local_f" ]] || { log "WARN: local yok — $rel"; continue; }
  local_hash="$(canonical_hash "$local_f")"
  remote_hash="$(canonical_hash_remote "$REMOTE_DIR/$rel" || true)"
  if [[ -z "$remote_hash" ]]; then
    log "DRIFT missing: $rel (Pi dosya yok)"
    fail=1
    continue
  fi
  if [[ "$local_hash" != "$remote_hash" ]]; then
    log "DRIFT hash: $rel"
    log "  local : $local_hash"
    log "  remote: $remote_hash"
    fail=1
  else
    ok "$rel"
  fi
done

if [[ "$fail" -ne 0 ]]; then
  die "config drift — make render && make deploy veya make sync-configs"
fi
log "Tamamlandi — drift yok"
