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
  local d="$1" failure_list token line saw_line=0
  [[ -z "$d" ]] && return 1
  [[ "$d" == *sd_fail=1* ]] && return 0
  if [[ "$d" == *"failures="* ]]; then
    failure_list="${d#*failures=}"
    for token in $failure_list; do
      case "$token" in
        ssd-unmounted|ssd-unhealthy|storage-degraded*|data-ssd-symlink*|data-native-missing) ;;
        offsite-*|restic-offsite-*|optional-*|backup-restore-drill*|bulletin-*|hermes-session-*|hermes-token-*|exit_code=*) ;;
        *) return 1 ;;
      esac
    done
    [[ -n "$failure_list" ]]
    return
  fi
  while IFS= read -r line; do
    line="${line#"${line%%[![:space:]]*}"}"
    line="${line#FAIL }"
    line="${line#SLO }"
    [[ -z "$line" ]] && continue
    saw_line=1
    case "$line" in
      ssd-unmounted|ssd-unhealthy|storage-degraded*|data-ssd-symlink*|data-native-missing) ;;
      offsite-*|restic-offsite-*|optional-*|backup-restore-drill*|bulletin-*|hermes-session-*|hermes-token-*|exit_code=0) ;;
      *) return 1 ;;
    esac
  done < <(printf '%s' "$d" | tr ';' '\n' | sort -u)
  [[ "$saw_line" -eq 1 ]]
}

if [[ "${1:-}" == "--self-check" ]]; then
  notify_failure_skip_sla_only "exit_code=1; failures=ssd-unmounted" || exit 1
  notify_failure_skip_sla_only "SLO offsite-stale" || exit 1
  notify_failure_skip_sla_only "exit_code=1; failures=container unbound down" && exit 1
  echo "[notify-failure] self-check OK"
  exit 0
fi

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
