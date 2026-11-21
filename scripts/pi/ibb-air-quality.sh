#!/usr/bin/env bash
# İBB HKI scrape → Prometheus textfile + Jarvis (eşik geçişi)
set -euo pipefail
_PI_STATE_USER="${PI_USER:-${SUDO_USER:-${USER:-pi}}}"
REMOTE_DIR="${REMOTE_DIR:-/home/${_PI_STATE_USER}/pi-gateway}"
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PY="${SCRIPT_DIR}/../lib/ibb-air-quality.py"
[[ -f "$PY" ]] || PY="${REMOTE_DIR}/scripts/lib/ibb-air-quality.py"

if [[ "${1:-}" == "--self-check" ]]; then
  python3 "$PY" --self-check
  exit 0
fi

_PG_ENV_LIB="${SCRIPT_DIR}/../lib/env-file.sh"
PG_SCRIPT_NAME="$(basename "$0")"
# shellcheck source=../lib/env-file.sh
source "${_PG_ENV_LIB:?}"
read_remote_dotenv || { echo "[${PG_SCRIPT_NAME}] HATA: .env dotenv parser hatasi" >&2; exit 1; }
# shellcheck source=../lib/notify.sh
source "$SCRIPT_DIR/../lib/notify.sh"

export PI_GATEWAY_METRICS_DIR="${PI_GATEWAY_METRICS_DIR:-/var/lib/pi-gateway/metrics}"
export IBB_HKI_WARN="${IBB_HKI_WARN:-101}"
export IBB_HTTP_TIMEOUT_SEC="${IBB_HTTP_TIMEOUT_SEC:-20}"
export IBB_AQI_STATION_ID="${IBB_AQI_STATION_ID:-}"
export IBB_HOME_LAT="${IBB_HOME_LAT:-${QUAKE_HOME_LAT:-41.0082}}"
export IBB_HOME_LON="${IBB_HOME_LON:-${QUAKE_HOME_LON:-28.9784}}"

PROM_TMP="$(mktemp)"
trap 'rm -f "$PROM_TMP"' EXIT
export PI_GATEWAY_IBB_PROM="$PROM_TMP"

line="$(python3 "$PY" || true)"
[[ -n "$line" ]] || line="status=fail reason=exit"
echo "[ibb-air] $line"

install_ibb_prom() {
  [[ -s "$PROM_TMP" ]] || return 0
  local out="${PI_GATEWAY_METRICS_DIR}/pi_gateway_ibb.prom"
  local stage="${out}.tmp.$$"
  local owner="${PI_USER:-${_PI_STATE_USER}}"
  if [[ -z "$owner" || "$owner" == "root" ]]; then
    owner="$(stat -c '%U' "$REMOTE_DIR" 2>/dev/null || echo "${_PI_STATE_USER}")"
  fi
  if [[ "$(id -u)" -eq 0 ]]; then
    mkdir -p "$PI_GATEWAY_METRICS_DIR"
    install -m 644 "$PROM_TMP" "$stage"
    [[ "$owner" != "root" ]] && chown "${owner}:${owner}" "$stage" 2>/dev/null || true
    mv -f "$stage" "$out"
  elif [[ -d "$PI_GATEWAY_METRICS_DIR" && -w "$PI_GATEWAY_METRICS_DIR" && ( ! -e "$out" || -w "$out" ) ]]; then
    install -m 644 "$PROM_TMP" "$stage"
    mv -f "$stage" "$out"
  else
    sudo mkdir -p "$PI_GATEWAY_METRICS_DIR"
    sudo install -m 644 "$PROM_TMP" "$stage"
    [[ "$owner" != "root" ]] && sudo chown "${owner}:${owner}" "$stage" 2>/dev/null || true
    sudo mv -f "$stage" "$out"
  fi
}
install_ibb_prom

ibb_human_detail() {
  python3 - "$1" "${IBB_HKI_WARN}" <<'PY'
import re, sys

line, warn = sys.argv[1], sys.argv[2]
keys = ("status", "station", "hki", "pollutant", "read", "state")
pat = re.compile(r"(?:^|\s)(" + "|".join(keys) + r")=")
matches = list(pat.finditer(line))
fields = {}
for idx, m in enumerate(matches):
    end = matches[idx + 1].start() if idx + 1 < len(matches) else len(line)
    fields[m.group(1)] = line[m.end():end].strip()

print(
    f"İstasyon: {fields.get('station') or '?'}\n"
    f"HKI: {fields.get('hki') or '?'} (eşik {warn})\n"
    f"Kirletici: {fields.get('pollutant') or '?'}\n"
    f"Ölçüm: {fields.get('read') or '?'}\n"
    f"Durum: {fields.get('state') or '?'}"
)
PY
}

status=""
case "$line" in
  status=warn*) status=warn ;;
  status=ok*) status=ok ;;
  *) status=fail ;;
esac
case "$status" in
  warn) notify_ibb_hki_warn "$(ibb_human_detail "$line")" || true ;;
  ok) notify_ibb_hki_ok || true ;;
  *) logger -t pi-gateway-ibb "WARN scrape: $line" || true ;;
esac
