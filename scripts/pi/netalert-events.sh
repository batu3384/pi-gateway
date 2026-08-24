#!/usr/bin/env bash
# NetAlertX Events poll — paylaşılan çekirdek (new_device | offline).
set -uo pipefail
STREAM="${1:?stream: new_device|offline}"
REMOTE_DIR="${REMOTE_DIR:-/home/${USER}/pi-gateway}"
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
LIB="${SCRIPT_DIR}/../lib/netalert-devices.py"
DB="${NETALERTX_DB:-${REMOTE_DIR}/data/netalertx/db/app.db}"
STATE="${NETALERTX_STATE:-/var/lib/pi-gateway/netalert-state.json}"
LEGACY_MACS="${NETALERTX_KNOWN_MACS:-/var/lib/pi-gateway/netalert-known-macs.txt}"
TMP=""

cleanup() { [[ -n "$TMP" && -f "$TMP" ]] && rm -f "$TMP"; }
trap cleanup EXIT

die_silent() {
  echo "[SILENT] $*" >&2
  exit 0
}

fail() {
  echo "[netalert] HATA: $*" >&2
  exit 1
}

_ensure_db_access() {
  local fix="${SCRIPT_DIR}/ensure-netalert-db-access.sh"
  [[ -x "$fix" ]] || fix="${SCRIPT_DIR}/ensure-netalert-db-access.sh"
  if [[ -f "$fix" ]]; then
    bash "$fix" || fail "NetAlertX DB izinleri duzeltilemedi — ensure-netalert-db-access.sh"
  fi
  [[ -r "$DB" ]] || fail "NetAlertX DB okunamiyor ($DB). Pi: bash scripts/pi/ensure-netalert-db-access.sh"
}

_json_field() {
  python3 - "$1" "$2" <<'PY'
import json, sys
v = json.load(open(sys.argv[1])).get(sys.argv[2])
print("" if v is None else v)
PY
}

[[ -d "$(dirname "$DB")" ]] || die_silent "NetAlertX DB dizini yok."
_ensure_db_access
[[ -f "$DB" ]] || die_silent "NetAlertX DB yok."
[[ -f "$LIB" ]] || fail "netalert-devices.py yok."

_ensure_state_dir() {
  local dir="$1" file="$2" u="${USER:-pi}"
  if [[ ! -d "$dir" ]]; then
    sudo mkdir -p "$dir" 2>/dev/null || mkdir -p "$dir" 2>/dev/null || return 1
  fi
  if [[ ! -w "$dir" ]]; then
    sudo chown "${u}:${u}" "$dir" 2>/dev/null || true
    sudo chmod 775 "$dir" 2>/dev/null || true
  fi
  if [[ -f "$file" && ! -w "$file" ]]; then
    sudo chown "${u}:${u}" "$file" 2>/dev/null || true
    sudo chmod 664 "$file" 2>/dev/null || true
  fi
  [[ -w "$dir" ]]
}
_ensure_state_dir "$(dirname "$STATE")" "$STATE" || fail "state dizini yazilamaz: $(dirname "$STATE")"

if [[ ! -f "$STATE" ]]; then
  if [[ -f "$LEGACY_MACS" && "$STREAM" == "new_device" ]]; then
    python3 "$LIB" --db "$DB" --state "$STATE" --bootstrap || fail "bootstrap basarisiz"
    die_silent "NetAlertX state bootstrap (legacy MAC listesi)."
  fi
  python3 "$LIB" --db "$DB" --state "$STATE" --bootstrap || fail "bootstrap basarisiz"
  die_silent "NetAlertX state bootstrap tamam."
fi

TMP="$(mktemp)"
_poll_rc=0
python3 "$LIB" --db "$DB" --state "$STATE" --stream "$STREAM" --emit envelope >"$TMP" || _poll_rc=$?

if (( _poll_rc == 2 )); then
  python3 "$LIB" --db "$DB" --state "$STATE" --bootstrap || fail "state repair bootstrap basarisiz"
  die_silent "NetAlertX state onarildi (bootstrap)."
fi
(( _poll_rc == 0 )) || fail "poll basarisiz (kod $_poll_rc)"

count="$(_json_field "$TMP" count)"
max_rowid="$(_json_field "$TMP" max_rowid)"
plain="$(_json_field "$TMP" plain)"
html_detail="$(_json_field "$TMP" html_detail)"

[[ "$count" =~ ^[0-9]+$ ]] || fail "count parse hatasi"
[[ "$max_rowid" =~ ^[0-9]+$ ]] || fail "max_rowid parse hatasi"

(( max_rowid > 0 )) || die_silent "Yeni olay yok."

if (( count == 0 )); then
  python3 "$LIB" --db "$DB" --state "$STATE" --stream "$STREAM" --commit-rowid "$max_rowid" \
    || fail "cursor commit basarisiz (filtreli olaylar)"
  die_silent "Yeni olay yok."
fi

[[ -n "$plain" ]] || fail "poll count=$count ama plain bos"

if [[ "${NETALERT_NOTIFY_BOT:-0}" == "1" ]]; then
  # shellcheck source=../lib/env-file.sh
  source "${SCRIPT_DIR}/../lib/env-file.sh"
  read_remote_dotenv || true
  # shellcheck source=../lib/notify.sh
  source "${SCRIPT_DIR}/../lib/notify.sh"
  if [[ "$STREAM" == "offline" ]]; then
    notify_netalert_offline_devices "$html_detail" "$count" || true
  else
    notify_netalert_new_devices "$html_detail" "$count" || true
  fi
fi

python3 "$LIB" --db "$DB" --state "$STATE" --stream "$STREAM" --commit-rowid "$max_rowid" \
  || fail "cursor commit basarisiz (pre-output)"
printf '%s\n' "$plain" | bash "${SCRIPT_DIR}/../lib/archive-bulletin.sh" "netalert-${STREAM}"
