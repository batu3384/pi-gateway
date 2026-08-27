#!/usr/bin/env bash
# İBB HKI scrape → Prometheus textfile + Telegram (eşik geçişi)
set -euo pipefail
REMOTE_DIR="${REMOTE_DIR:-/home/${USER}/pi-gateway}"
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
load_telegram_from_hermes || true
# shellcheck source=../lib/notify.sh
source "$SCRIPT_DIR/../lib/notify.sh"

export PI_GATEWAY_METRICS_DIR="${PI_GATEWAY_METRICS_DIR:-/var/lib/pi-gateway/metrics}"
export IBB_HKI_WARN="${IBB_HKI_WARN:-51}"
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
  if [[ "$(id -u)" -eq 0 ]]; then
    mkdir -p "$PI_GATEWAY_METRICS_DIR"
    install -m 644 "$PROM_TMP" "$PI_GATEWAY_METRICS_DIR/pi_gateway_ibb.prom"
    chown "${USER}:${USER}" "$PI_GATEWAY_METRICS_DIR/pi_gateway_ibb.prom" 2>/dev/null || true
  else
    sudo mkdir -p "$PI_GATEWAY_METRICS_DIR"
    sudo install -m 644 "$PROM_TMP" "$PI_GATEWAY_METRICS_DIR/pi_gateway_ibb.prom"
    sudo chown "${USER}:${USER}" "$PI_GATEWAY_METRICS_DIR/pi_gateway_ibb.prom" 2>/dev/null || true
  fi
}
install_ibb_prom

ibb_human_detail() {
  local tok station="" hki="" pollutant="" readt="" state=""
  local -a parts
  read -ra parts <<< "$1"
  for tok in "${parts[@]}"; do
    case "$tok" in
      station=*) station="${tok#station=}" ;;
      hki=*) hki="${tok#hki=}" ;;
      pollutant=*) pollutant="${tok#pollutant=}" ;;
      read=*) readt="${tok#read=}" ;;
      state=*) state="${tok#state=}" ;;
    esac
  done
  printf 'İstasyon: %s\nHKI: %s (eşik %s)\nKirletici: %s\nÖlçüm: %s\nDurum: %s' \
    "${station:-?}" "${hki:-?}" "${IBB_HKI_WARN}" "${pollutant:-?}" "${readt:-?}" "${state:-?}"
}

status=""
case "$line" in
  status=warn*) status=warn ;;
  status=ok*) status=ok ;;
  *) status=fail ;;
esac
case "$status" in
  warn) notify_ibb_hki_warn "$(ibb_human_detail "$line")" ;;
  ok) notify_ibb_hki_ok ;;
  *) logger -t pi-gateway-ibb "WARN scrape: $line" || true ;;
esac
