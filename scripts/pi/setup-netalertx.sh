#!/usr/bin/env bash
# NetAlertX: subnet tarama, webhook (n8n), plugin ayarlari
set -euo pipefail

REMOTE_DIR="${REMOTE_DIR:-/home/${USER}/pi-gateway}"
# shellcheck source=/dev/null
[[ -f "$REMOTE_DIR/.env" ]] && source "$REMOTE_DIR/.env"

NETALERTX_PORT="${NETALERTX_PORT:-20211}"
NETALERTX_LISTEN_ADDR="${NETALERTX_LISTEN_ADDR:-0.0.0.0}"
NETALERTX_PASSWORD="${NETALERTX_PASSWORD:-${AGH_ADMIN_PASSWORD:-}}"
PI_STATIC_IP="${PI_STATIC_IP:-}"
PI_INTERFACE="${PI_INTERFACE:-eth0}"
LAN_SUBNET_CIDR="${LAN_SUBNET_CIDR:-192.168.1.0/24}"
LAN_DOMAIN="${LAN_DOMAIN:-home}"
N8N_PORT="${N8N_PORT:-5678}"
PANEL_PROTOCOL="${PANEL_PROTOCOL:-https}"
if [[ "${ENABLE_TLS:-false}" != "true" ]]; then
  PANEL_PROTOCOL=http
fi
ADGUARD_WEB_PORT="${ADGUARD_WEB_PORT:-8080}"
AGH_ADMIN_USER="${AGH_ADMIN_USER:-admin}"
AGH_ADMIN_PASSWORD="${AGH_ADMIN_PASSWORD:-}"
DATA_DIR="${REMOTE_DIR}/data/netalertx"
CONF_FILE="${DATA_DIR}/config/app.conf"
MARKER="${DATA_DIR}/.pi-gateway-configured"

log() { echo "[netalertx-setup] $*"; }

[[ "${ENABLE_NETALERTX:-true}" == "true" ]] || { log "NetAlertX kapali"; exit 0; }
[[ -n "${NETALERTX_PASSWORD:-}" ]] || { log "HATA: NETALERTX_PASSWORD veya AGH_ADMIN_PASSWORD gerekli"; exit 1; }
[[ -n "${AGH_ADMIN_PASSWORD:-}" ]] || { log "HATA: AGH_ADMIN_PASSWORD gerekli (ADGUARDIMP)"; exit 1; }
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
  local _
  for _ in $(seq 1 36); do
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

export CONF_FILE SCAN_SUBNET WEBHOOK_URL MARKER PANEL_PROTOCOL LAN_DOMAIN NETALERTX_PASSWORD
export AGH_ADMIN_USER AGH_ADMIN_PASSWORD ADGUARD_WEB_PORT
SCAN_SUBNET="$(scan_subnet)"
WEBHOOK_URL="$(webhook_url)"
# shellcheck disable=SC2089,SC2090 # JSON string passed to python via env
PLUGINS='["ARPSCAN","DIGSCAN","NSLOOKUP","ICMP","WEBHOOK","NEWDEV","NTFPRCS","DBCLNP","CUSTPROP","SETPWD","SYNC","UI","MAINT","VNDRPDT","ADGUARDIMP","AVAHISCAN"]'
# shellcheck disable=SC2090
export SCAN_SUBNET WEBHOOK_URL PLUGINS

python3 <<'PY'
import os
import re
import time
from pathlib import Path

conf = Path(os.environ["CONF_FILE"])
marker = Path(os.environ["MARKER"])
subnet = os.environ["SCAN_SUBNET"]
webhook = os.environ["WEBHOOK_URL"]
password = os.environ["NETALERTX_PASSWORD"]
password_hash = __import__("hashlib").sha256(password.encode()).hexdigest()
agh_user = os.environ.get("AGH_ADMIN_USER", "admin")
agh_pass = os.environ["AGH_ADMIN_PASSWORD"]
agh_port = os.environ.get("ADGUARD_WEB_PORT", "8080")
plugins = os.environ.get("PLUGINS", "[]")
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
    "LOADED_PLUGINS": plugins,
    "SCAN_SUBNETS": scan_value,
    "WEBHOOK_URL": f"'{webhook}'",
    "WEBHOOK_REQUEST_METHOD": "'POST'",
    "WEBHOOK_RUN": "'on_notification'",
    "WEBHOOK_REPORT_TYPE": "'preset'",
    "ICMP_RUN": "'schedule'",
    "ARPSCAN_RUN": "'schedule'",
    "DIGSCAN_RUN": "'schedule'",
    "AVAHISCAN_RUN": "'before_name_updates'",
    "NSLOOKUP_RUN": "'before_name_updates'",
    "ADGUARDIMP_RUN": "'schedule'",
    "ADGUARDIMP_RUN_SCHD": "'*/5 * * * *'",
    "ADGUARDIMP_RUN_TIMEOUT": "30",
    "ADGUARDIMP_SERVER": "'127.0.0.1'",
    "ADGUARDIMP_PORT": agh_port,
    "ADGUARDIMP_PROTOCOL": "'http'",
    "ADGUARDIMP_USER": "'" + agh_user.replace("'", "\\'") + "'",
    "ADGUARDIMP_PASS": "'" + agh_pass.replace("'", "\\'") + "'",
    "ADGUARDIMP_FAKE_MAC": "False",
    "SETPWD_enable_password": "True",
    "SETPWD_password": "'" + password_hash + "'",
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
    _u = os.environ.get("USER") or os.environ.get("PI_USER") or "pi"
    subprocess.run(["sudo", "chown", f"{_u}:{_u}", str(marker)], check=False)
    print(f"[netalertx-setup] app.conf guncellendi (SCAN_SUBNETS={subnet})")
    print(f"[netalertx-setup] WEBHOOK_URL={webhook}")
else:
    print("[netalertx-setup] app.conf zaten guncel")
PY

if [[ "$(cat "$MARKER" 2>/dev/null)" == "ok" ]]; then
  docker restart netalertx >/dev/null 2>&1 || true
  wait_http || true
fi

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
bash "$SCRIPT_DIR/import-adguard-names-to-netalertx.sh" || log "WARN: AdGuard isim importu atlandi"
bash "$SCRIPT_DIR/enrich-netalertx-names.sh"
bash "$SCRIPT_DIR/sync-adguard-persistent-clients.sh" || log "WARN: AdGuard istemci senkronu atlandi"

log "Tamamlandi — https://devices.${LAN_DOMAIN:-home}"
log "Giris: NetAlertX UI sifresi (NETALERTX_PASSWORD veya AGH_ADMIN_PASSWORD)"
