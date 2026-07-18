#!/usr/bin/env bash
# NetAlertX: subnet tarama, webhook (n8n), plugin ayarlari
set -euo pipefail

REMOTE_DIR="${REMOTE_DIR:-/home/${USER}/pi-gateway}"
# shellcheck source=/dev/null
[[ -f "$REMOTE_DIR/.env" ]] && source "$REMOTE_DIR/.env"

NETALERTX_PORT="${NETALERTX_PORT:-20211}"
NETALERTX_LISTEN_ADDR="${NETALERTX_LISTEN_ADDR:-0.0.0.0}"
PI_STATIC_IP="${PI_STATIC_IP:-192.168.1.112}"
PI_INTERFACE="${PI_INTERFACE:-eth0}"
LAN_SUBNET_CIDR="${LAN_SUBNET_CIDR:-192.168.1.0/24}"
LAN_DOMAIN="${LAN_DOMAIN:-home}"
N8N_PORT="${N8N_PORT:-5678}"
PANEL_PROTOCOL="${PANEL_PROTOCOL:-https}"
if [[ "${ENABLE_TLS:-false}" != "true" ]]; then
  PANEL_PROTOCOL=http
fi
DATA_DIR="${REMOTE_DIR}/data/netalertx"
CONF_FILE="${DATA_DIR}/config/app.conf"
MARKER="${DATA_DIR}/.pi-gateway-configured"

log() { echo "[netalertx-setup] $*"; }

[[ "${ENABLE_NETALERTX:-true}" == "true" ]] || { log "NetAlertX kapali"; exit 0; }
docker ps --format '{{.Names}}' | grep -q '^netalertx$' || { log "HATA: netalertx container yok"; exit 1; }

case "${N8N_WEBHOOK_SECRET:-}" in
  ""|CHANGE_ME*)
    [[ "${ENABLE_N8N:-true}" != "true" ]] || { log "HATA: N8N_WEBHOOK_SECRET gerekli"; exit 1; }
    ;;
esac

scan_subnet() {
  if [[ -n "${NETALERTX_SCAN_SUBNETS:-}" ]]; then
    printf '%s' "${NETALERTX_SCAN_SUBNETS}"
    return 0
  fi
  printf '%s --interface=%s' "${LAN_SUBNET_CIDR}" "${PI_INTERFACE}"
}

webhook_url() {
  local secret="${N8N_WEBHOOK_SECRET:-}"
  printf 'http://127.0.0.1:%s/webhook/netalert-device-alert-%s' "$N8N_PORT" "$secret"
}

wait_http() {
  local i
  for i in $(seq 1 36); do
    if curl -fsS "http://127.0.0.1:${NETALERTX_PORT}/" >/dev/null 2>&1; then
      return 0
    fi
    sleep 5
  done
  log "HATA: NetAlertX HTTP hazir degil (port ${NETALERTX_PORT})"
  return 1
}

mkdir -p "${DATA_DIR}/config" "${DATA_DIR}/db"
chown -R 20211:20211 "${DATA_DIR}" 2>/dev/null || sudo chown -R 20211:20211 "${DATA_DIR}" 2>/dev/null || true

wait_http

export CONF_FILE SCAN_SUBNET WEBHOOK_URL MARKER PANEL_PROTOCOL LAN_DOMAIN
SCAN_SUBNET="$(scan_subnet)"
WEBHOOK_URL="$(webhook_url)"
export SCAN_SUBNET WEBHOOK_URL

python3 <<'PY'
import os
import re
import time
from pathlib import Path

conf = Path(os.environ["CONF_FILE"])
marker = Path(os.environ["MARKER"])
subnet = os.environ["SCAN_SUBNET"]
webhook = os.environ["WEBHOOK_URL"]
lan = os.environ.get("LAN_DOMAIN", "home")
proto = os.environ.get("PANEL_PROTOCOL", "https")
dashboard = f"{proto}://devices.{lan}"
scan_value = f"['{subnet}']"

for _ in range(36):
    if conf.is_file() and conf.stat().st_size > 10:
        break
    time.sleep(5)
else:
    raise SystemExit("[netalertx-setup] HATA: app.conf olusmadi — container loglarina bakin")

text = conf.read_text()
updates = {
    "SCAN_SUBNETS": scan_value,
    "WEBHOOK_URL": f"'{webhook}'",
    "WEBHOOK_REQUEST_METHOD": "'POST'",
    "WEBHOOK_RUN": "'on_notification'",
    "WEBHOOK_REPORT_TYPE": "'preset'",
    "ICMP_RUN": "'schedule'",
    "ARPSCAN_RUN": "'schedule'",
    "DIGSCAN_RUN": "'schedule'",
    "SETPWD_enable_password": "False",
    "BACKEND_API_URL": "'/server'",
    "REPORT_DASHBOARD_URL": f"'{dashboard}'",
}
changed = False

for key, value in updates.items():
    pattern = rf"^{re.escape(key)}\s*=.*$"
    replacement = f"{key}={value}"
    if re.search(pattern, text, flags=re.MULTILINE):
        new_text, n = re.subn(pattern, replacement, text, count=1, flags=re.MULTILINE)
        if n and new_text != text:
            text = new_text
            changed = True
    else:
        text = text.rstrip() + "\n" + replacement + "\n"
        changed = True

if changed or not marker.is_file():
    import subprocess
    import tempfile
    with tempfile.NamedTemporaryFile("w", delete=False, suffix=".conf") as fh:
        fh.write(text)
        tmp_path = fh.name
    subprocess.run(["sudo", "cp", tmp_path, str(conf)], check=True)
    subprocess.run(["sudo", "chown", "20211:20211", str(conf)], check=True)
    Path(tmp_path).unlink(missing_ok=True)
    subprocess.run(["sudo", "tee", str(marker)], input=b"ok\n", check=True, stdout=subprocess.DEVNULL)
    subprocess.run(["sudo", "chown", f"{os.environ.get('USER', 'batu')}:batu", str(marker)], check=False)
    print(f"[netalertx-setup] app.conf guncellendi (SCAN_SUBNETS={subnet})")
    print(f"[netalertx-setup] WEBHOOK_URL={webhook}")
else:
    print("[netalertx-setup] app.conf zaten guncel")
PY

if [[ "$(cat "$MARKER" 2>/dev/null)" == "ok" ]]; then
  docker restart netalertx >/dev/null 2>&1 || true
  wait_http || true
fi

log "Tamamlandi — https://devices.${LAN_DOMAIN:-home}"
log "Giris: Caddy basic_auth (${CADDY_AUTH_USER:-${AGH_ADMIN_USER:-admin}}) — logs.home ile ayni sifre"
