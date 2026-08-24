#!/usr/bin/env bash
# systemd OnFailure — yalnizca health-check cekirdek fail (sd_fail haric).
set -euo pipefail
REMOTE_DIR="${REMOTE_DIR:-/home/${USER}/pi-gateway}"
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
_PG_ENV_LIB="${SCRIPT_DIR:-$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)}/../lib/env-file.sh"
PG_SCRIPT_NAME="$(basename "$0")"
# shellcheck source=../lib/env-file.sh
source "${_PG_ENV_LIB:?}"
read_remote_dotenv || { echo "[${PG_SCRIPT_NAME:-script}] HATA: .env dotenv parser hatasi" >&2; exit 1; }
source "$SCRIPT_DIR/../lib/notify.sh"

host="$(hostname -s 2>/dev/null || echo pi-gateway)"
details=""

if [[ -f /run/pi-gateway/health-last-exit.txt ]]; then
  details="$(tr '\n' '; ' < /run/pi-gateway/health-last-exit.txt | sed 's/; $//')"
fi
if [[ -z "$details" ]]; then
  details="$(
    journalctl -t pi-gateway-health -n 40 --no-pager 2>/dev/null \
      | grep -E ' FAIL ' \
      | tail -5 \
      | sed -E 's/^[^ ]+ [^ ]+ [^ ]+ [^ ]+ //; s/^pi-gateway-health\[[0-9]+\]: //' \
      | tr '\n' '; ' \
      | sed 's/; $//' || true
  )"
fi

# SLA yalniz — health-check zaten notify_slo_backup gonderdi
if [[ "$details" == failures=offsite-* ]]; then
  exit 0
fi
if [[ -z "$details" ]]; then
  details="Cekirdek kontrol basarisiz (ayrinti journal'da)."
fi

notify_health_systemd_fail "$host" "$details"
