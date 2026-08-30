#!/usr/bin/env bash
# NetAlertX: ARP envanter, AdGuard isim, yeni cihaz Telegram (sendMessage)
set -euo pipefail
REMOTE_DIR="${REMOTE_DIR:-/home/${USER}/pi-gateway}"
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
_PG_ENV_LIB="${SCRIPT_DIR}/../lib/env-file.sh"
PG_SCRIPT_NAME="$(basename "$0")"
# shellcheck source=../lib/env-file.sh
source "${_PG_ENV_LIB:?}"
read_remote_dotenv || { echo "[${PG_SCRIPT_NAME:-script}] HATA: .env dotenv parser hatasi" >&2; exit 1; }
log() { echo "[netalertx-setup] $*"; }
# shellcheck source=../lib/reap-dead-docker-scopes.sh
source "${SCRIPT_DIR}/../lib/reap-dead-docker-scopes.sh"
NETALERT_NOTIFY_VIA="${NETALERT_NOTIFY_VIA:-telegram}"
[[ "${NETALERT_NOTIFY_VIA}" == "hermes" ]] && NETALERT_NOTIFY_VIA=telegram
if [[ "${NETALERT_NOTIFY_VIA}" != "telegram" ]]; then
  log "HATA: NETALERT_NOTIFY_VIA=telegram gerekli (n8n yolu yok)"
  exit 1
fi
NETALERTX_PORT="${NETALERTX_PORT:-20211}"
NETALERTX_LISTEN_ADDR="${NETALERTX_LISTEN_ADDR:-172.17.0.1}"
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

_ensure_netalert_host_gid() {
  local env_file="${REMOTE_DIR}/.env" want
  want="$(id -g)"
  [[ -f "$env_file" ]] || return 1
  if grep -q '^NETALERTX_GID=' "$env_file" 2>/dev/null; then
    grep -q "^NETALERTX_GID=${want}$" "$env_file" && return 1
    sed -i "s/^NETALERTX_GID=.*/NETALERTX_GID=${want}/" "$env_file" 2>/dev/null || \
      sed -i '' "s/^NETALERTX_GID=.*/NETALERTX_GID=${want}/" "$env_file"
  else
    {
      echo ""
      echo "# Host grubu — app.db okuma (NETALERTX_UID=20211 kalir)"
      echo "NETALERTX_GID=${want}"
    } >>"$env_file"
  fi
  export NETALERTX_GID="$want"
  return 0
}

_netalert_gid_changed=0
_ensure_netalert_host_gid && _netalert_gid_changed=1 || true

[[ "${ENABLE_NETALERTX:-true}" == "true" ]] || { log "NetAlertX kapali"; exit 0; }
[[ -n "${NETALERTX_PASSWORD:-}" ]] || { log "HATA: NETALERTX_PASSWORD veya AGH_ADMIN_PASSWORD gerekli"; exit 1; }
[[ "${#NETALERTX_PASSWORD}" -ge 12 ]] \
  || { log "HATA: NETALERTX_PASSWORD en az 12 karakter olmali"; exit 1; }
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
  printf ''
}
wait_http() {
  local _
  local url="http://${NETALERTX_LISTEN_ADDR}:${NETALERTX_PORT}/"
  for _ in $(seq 1 36); do
    if curl -fsS -L --max-time 3 "$url" >/dev/null 2>&1; then
      return 0
    fi
    # Fallback: n8n restart sonrasi container ayaga kalkana kadar
    if curl -fsS -L --max-time 3 "http://127.0.0.1:${NETALERTX_PORT}/" >/dev/null 2>&1; then
      return 0
    fi
    sleep 5
  done
  log "HATA: NetAlertX HTTP hazir degil (${NETALERTX_LISTEN_ADDR}:${NETALERTX_PORT})"
  return 1
}
# Host-network leftover nginx/python (ölü docker-*.scope) 20211/20214 tutar.
_reap_netalert_binds() {
  docker stop netalertx >/dev/null 2>&1 || true
  reap_dead_docker_scopes || true
  sudo fuser -k "${NETALERTX_PORT}/tcp" >/dev/null 2>&1 || true
  sudo fuser -k 20214/tcp >/dev/null 2>&1 || true
  sleep 1
}
mkdir -p "${DATA_DIR}/config" "${DATA_DIR}/db"
chown -R "20211:$(id -gn)" "${DATA_DIR}" 2>/dev/null || sudo chown -R "20211:$(id -gn)" "${DATA_DIR}" 2>/dev/null || true
reap_dead_docker_scopes || true
if ! curl -fsS -L --max-time 3 "http://${NETALERTX_LISTEN_ADDR}:${NETALERTX_PORT}/" >/dev/null 2>&1 \
  && ! curl -fsS -L --max-time 3 "http://127.0.0.1:${NETALERTX_PORT}/" >/dev/null 2>&1; then
  log "HTTP yok — stale bind reap"
  _reap_netalert_binds
  docker start netalertx >/dev/null 2>&1 || true
fi
wait_http
export CONF_FILE SCAN_SUBNET MARKER PANEL_PROTOCOL LAN_DOMAIN NETALERTX_PASSWORD
export AGH_ADMIN_USER AGH_ADMIN_PASSWORD ADGUARD_WEB_PORT NETALERT_NOTIFY_VIA
export TELEGRAM_BOT_TOKEN="${TELEGRAM_BOT_TOKEN:-}" TELEGRAM_CHAT_ID="${TELEGRAM_CHAT_ID:-}"
SCAN_SUBNET="$(scan_subnet)"
WEBHOOK_URL="$(webhook_url)"
export NETALERT_WEBHOOK_RAW="$WEBHOOK_URL"
log "NetAlertX webhook kapali — Telegram plugin sendMessage"
# ARP + AdGuard isim + zorunlu iskelet + TELEGRAM. ICMP/DIG/vendor/webhook yok.
export NETALERTX_PLUGINS='["ARPSCAN","ADGUARDIMP","NEWDEV","NTFPRCS","DBCLNP","CUSTPROP","SETPWD","SYNC","UI","MAINT","TELEGRAM"]'
export SCAN_SUBNET
python3 <<'PY'
import os
import re
import subprocess
import time
from pathlib import Path
conf = Path(os.environ["CONF_FILE"])
marker = Path(os.environ["MARKER"])
subnet = os.environ["SCAN_SUBNET"]
notify_via = os.environ.get("NETALERT_NOTIFY_VIA", "telegram")
if notify_via == "hermes":
    notify_via = "telegram"
if notify_via != "telegram":
    raise SystemExit("[netalertx-setup] HATA: NETALERT_NOTIFY_VIA=telegram gerekli")
webhook = "''"
webhook_run = "'off'"
password = os.environ["NETALERTX_PASSWORD"]
# NetAlertX upstream contract: SETPWD_password is SHA-256, no alternate KDF.
password_hash = __import__("hashlib").sha256(password.encode()).hexdigest()
agh_user = os.environ.get("AGH_ADMIN_USER", "admin")
agh_pass = os.environ["AGH_ADMIN_PASSWORD"]
agh_port = os.environ.get("ADGUARD_WEB_PORT", "8080")
plugins = os.environ.get("NETALERTX_PLUGINS", "[]")
lan = os.environ.get("LAN_DOMAIN", "home")
proto = os.environ.get("PANEL_PROTOCOL", "https")
dashboard = f"{proto}://devices.{lan}"
scan_value = f"['{subnet}']"
tg_token = (os.environ.get("TELEGRAM_BOT_TOKEN") or "").strip()
tg_chat = (os.environ.get("TELEGRAM_CHAT_ID") or "").strip()

def q(val: str) -> str:
    return "'" + val.replace("\\", "\\\\").replace("'", "\\'") + "'"

telegram_run = "'on_notification'" if tg_token and tg_chat else "'disabled'"
if telegram_run == "'disabled'":
    print("[netalertx-setup] WARN: TELEGRAM_BOT_TOKEN/CHAT_ID yok — yeni cihaz bildirimi kapali")
text = ""
for _ in range(36):
    try:
        text = subprocess.check_output(["sudo", "cat", str(conf)], text=True)
    except (subprocess.CalledProcessError, FileNotFoundError):
        text = ""
    if len(text) > 10:
        break
    time.sleep(5)
else:
    raise SystemExit("[netalertx-setup] HATA: app.conf olusmadi — container loglarina bakin")
updates = {
    "LOADED_PLUGINS": plugins,
    "SCAN_SUBNETS": scan_value,
    "WEBHOOK_URL": webhook,
    "WEBHOOK_REQUEST_METHOD": "'POST'",
    "WEBHOOK_RUN": webhook_run,
    "WEBHOOK_REPORT_TYPE": "'preset'",
    "ICMP_RUN": "'disabled'",
    "ARPSCAN_RUN": "'schedule'",
    "ARPSCAN_RUN_SCHD": "'*/5 * * * *'",
    "DIGSCAN_RUN": "'disabled'",
    "AVAHISCAN_RUN": "'disabled'",
    "NSLOOKUP_RUN": "'disabled'",
    "VNDRPDT_RUN": "'disabled'",
    "ADGUARDIMP_RUN": "'schedule'",
    "ADGUARDIMP_RUN_SCHD": "'*/5 * * * *'",
    "ADGUARDIMP_RUN_TIMEOUT": "30",
    "ADGUARDIMP_SERVER": "'127.0.0.1'",
    "ADGUARDIMP_PORT": agh_port,
    "ADGUARDIMP_PROTOCOL": "'http'",
    "ADGUARDIMP_USER": q(agh_user),
    "ADGUARDIMP_PASS": q(agh_pass),
    "ADGUARDIMP_FAKE_MAC": "False",
    "NTFPRCS_INCLUDED_SECTIONS": "['new_devices']",
    "TELEGRAM_RUN": telegram_run,
    "TELEGRAM_HOST": q(tg_chat),
    "TELEGRAM_URL": q(tg_token),
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
    import tempfile
    with tempfile.NamedTemporaryFile("w", delete=False, suffix=".conf") as fh:
        fh.write(text)
        tmp_path = fh.name
    subprocess.run(["sudo", "cp", tmp_path, str(conf)], check=True)
    subprocess.run(["sudo", "chown", "20211:20211", str(conf)], check=True)
    subprocess.run(["sudo", "chmod", "600", str(conf)], check=True)
    Path(tmp_path).unlink(missing_ok=True)
    subprocess.run(["sudo", "tee", str(marker)], input=b"ok\n", check=True, stdout=subprocess.DEVNULL)
    _u = os.environ.get("USER") or os.environ.get("PI_USER") or "pi"
    subprocess.run(["sudo", "chown", f"{_u}:{_u}", str(marker)], check=False)
    print(f"[netalertx-setup] app.conf guncellendi (SCAN_SUBNETS={subnet})")
    print(f"[netalertx-setup] TELEGRAM_RUN={telegram_run} WEBHOOK_RUN={webhook_run}")
else:
    print("[netalertx-setup] app.conf zaten guncel")
PY
if [[ "$(cat "$MARKER" 2>/dev/null)" == "ok" ]]; then
  _reap_netalert_binds
  docker start netalertx >/dev/null 2>&1 || true
  wait_http || true
fi
# Isim sync: yalniz ADGUARDIMP plugin (*/5). Timer/import/enrich/geri-sync yok — cift yazici.
DB_DIR="${DATA_DIR}/db"
DB_FILE="${DB_DIR}/app.db"
_pi_gn="$(id -gn)"
if (( _netalert_gid_changed )); then
  log "NETALERTX_GID=${NETALERTX_GID:-$(id -g)} — container yeniden olusturuluyor"
  _reap_netalert_binds
  (cd "${REMOTE_DIR}/compose" && docker compose --env-file ../.env --profile netalert up -d --force-recreate netalertx) \
    || log "WARN: netalertx recreate basarisiz"
  wait_http || true
fi
_ensure_db_script="${SCRIPT_DIR}/ensure-netalert-db-access.sh"
if [[ -x "$_ensure_db_script" ]]; then
  bash "$_ensure_db_script" || { log "HATA: ensure-netalert-db-access"; exit 1; }
elif [[ -d "$DB_DIR" ]]; then
  chown 20211:"$_pi_gn" "$DB_DIR" 2>/dev/null || sudo chown 20211:"$_pi_gn" "$DB_DIR" 2>/dev/null || true
  chmod 775 "$DB_DIR" 2>/dev/null || sudo chmod 775 "$DB_DIR" 2>/dev/null || true
  if [[ -f "$DB_FILE" ]]; then
    for _dbf in "$DB_DIR"/app.db "$DB_DIR"/app.db-wal "$DB_DIR"/app.db-shm; do
      [[ -e "$_dbf" ]] || continue
      chown 20211:"$_pi_gn" "$_dbf" 2>/dev/null || sudo chown 20211:"$_pi_gn" "$_dbf" 2>/dev/null || true
      chmod 660 "$_dbf" 2>/dev/null || sudo chmod 660 "$_dbf" 2>/dev/null || true
    done
  fi
fi
log "Tamamlandi — https://devices.${LAN_DOMAIN:-home}"
log "Giris: NetAlertX UI sifresi (NETALERTX_PASSWORD veya AGH_ADMIN_PASSWORD)"
