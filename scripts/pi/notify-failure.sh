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

if [[ "${FAILURE_KIND:-}" == "adguard-filter" ]]; then
  notify_health_systemd_fail "$host" \
    "AdGuard filter timer basarisiz; eski son basarili filtreler korunuyor. journalctl -u pi-gateway-adguard-filters.service"
  exit 0
fi

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

# SLA / SD yalniz — health-check veya check-sd-health zaten bildirdi
notify_failure_skip_sla_only() {
  local d="$1" line
  [[ -z "$d" ]] && return 1
  [[ "$d" == failures=offsite-* ]] && return 0
  [[ "$d" == *sd_fail=1* ]] && return 0
  while IFS= read -r line; do
    line="${line#"${line%%[![:space:]]*}"}"
    line="${line#FAIL }"
    line="${line#SLO }"
    [[ -z "$line" ]] && continue
    case "$line" in
      offsite-*|optional-*|backup-restore-drill*|bulletin-*|hermes-session-*|exit_code=0) ;;
      *) return 1 ;;
    esac
  done < <(printf '%s' "$d" | tr ';' '\n' | sort -u)
  return 0
}

if notify_failure_skip_sla_only "$details"; then
  exit 0
fi
# Journal tekrarlarini tekillestir
if [[ "$details" == *';'* ]]; then
  details="$(printf '%s' "$details" | tr ';' '\n' | sed 's/^[[:space:]]*//' | sort -u | paste -sd '; ' -)"
fi
if [[ -z "$details" ]]; then
  details="Cekirdek kontrol basarisiz (ayrinti journal'da)."
fi

notify_health_systemd_fail "$host" "$details"
