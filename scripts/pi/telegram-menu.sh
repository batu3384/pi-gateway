#!/usr/bin/env bash
# Telegram: sabit durum kartı + panel inline butonları + ops komutları
set -euo pipefail
REMOTE_DIR="${REMOTE_DIR:-/home/${USER}/pi-gateway}"
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PANELS_PY="${REMOTE_DIR}/scripts/lib/telegram-panels.py"
CARD="${REMOTE_DIR}/scripts/pi/telegram-status-card.sh"
_PG_ENV_LIB="${SCRIPT_DIR}/../lib/env-file.sh"
PG_SCRIPT_NAME="$(basename "$0")"
# shellcheck source=../lib/env-file.sh
source "${_PG_ENV_LIB:?}"
read_remote_dotenv || { echo "[${PG_SCRIPT_NAME}] HATA: .env dotenv parser hatasi" >&2; exit 1; }
load_telegram_from_hermes || true
# shellcheck source=../lib/notify.sh
source "$SCRIPT_DIR/../lib/notify.sh"
log() { echo "[telegram-menu] $*"; }
notify_enabled || { log "TELEGRAM_BOT_TOKEN / TELEGRAM_CHAT_ID eksik"; exit 1; }
[[ -f "$PANELS_PY" ]] || { log "HATA: telegram-panels.py yok"; exit 1; }

if [[ -x "$REMOTE_DIR/scripts/pi/setup-tailscale-panel-ports.sh" ]]; then
  bash "$REMOTE_DIR/scripts/pi/setup-tailscale-panel-ports.sh" || log "WARN: ts-panel-ports"
fi

export LAN_DOMAIN PI_STATIC_IP PANEL_PROTOCOL ENABLE_TLS
export AGH_ADMIN_USER CADDY_AUTH_USER
export HERMES_TELEGRAM_GATEWAY
export DOZZLE_PORT ADGUARD_WEB_PORT N8N_PORT GRAFANA_PORT NETALERTX_PORT
export TELEGRAM_BOT_TOKEN TELEGRAM_CHAT_ID

API="https://api.telegram.org/bot${TELEGRAM_BOT_TOKEN}"

if [[ -x "$CARD" ]]; then
  bash "$CARD" --force || log "WARN: durum karti"
else
  log "HATA: telegram-status-card.sh yok"
  exit 1
fi

curl -fsS -X POST "${API}/setChatMenuButton" \
  -d "chat_id=${TELEGRAM_CHAT_ID}" \
  -d 'menu_button={"type":"commands"}' >/dev/null 2>&1 || true

_register_chat_panel_commands() {
  python3 - "$API" "$TELEGRAM_CHAT_ID" <<'PY'
import json, sys, urllib.parse, urllib.request

api, chat_id = sys.argv[1], sys.argv[2]
want = [
    ("menu", "Durum kartini yenile"),
    ("dns", "DNS kapsam ozeti"),
    ("ssd", "SSD / USB saglik"),
    ("backup", "Yedek durumu"),
    ("recover", "SSD yazilim kurtarma"),
]

def api_call(method, payload):
    data = urllib.parse.urlencode(payload).encode()
    req = urllib.request.Request(f"{api}/{method}", data=data, method="POST")
    with urllib.request.urlopen(req, timeout=20) as resp:
        return json.load(resp)

existing = api_call("getMyCommands", {})
cmds = []
seen = set()
for name, desc in want:
    cmds.append({"command": name, "description": desc[:40]})
    seen.add(name)
for c in existing.get("result") or []:
    name = str(c.get("command") or "")
    if not name or name in seen:
        continue
    cmds.append({"command": name, "description": str(c.get("description") or "")[:40]})
    seen.add(name)
    if len(cmds) >= 100:
        break
scope = json.dumps({"type": "chat", "chat_id": int(chat_id) if str(chat_id).lstrip("-").isdigit() else chat_id})
out = api_call("setMyCommands", {"commands": json.dumps(cmds), "scope": scope})
print("ok" if out.get("ok") else out, file=sys.stderr)
raise SystemExit(0 if out.get("ok") else 1)
PY
}

if [[ "$(python3 "$PANELS_PY" hermes_owns_inbox 2>/dev/null || echo 0)" == "1" ]]; then
  _register_chat_panel_commands || log "WARN: chat-scope komutlar"
else
  curl -fsS -X POST "${API}/setMyCommands" \
    -d 'commands=[{"command":"menu","description":"Durum kartini yenile"},{"command":"dns","description":"DNS kapsam ozeti"},{"command":"ssd","description":"SSD saglik"},{"command":"backup","description":"Yedek durumu"},{"command":"recover","description":"SSD kurtarma"}]' \
    >/dev/null 2>&1 || true
fi

# Eski sticky Paneller klavyesini kaldir (bir kez)
if [[ -f /var/lib/pi-gateway/telegram-status-card.json ]] \
  && grep -q '"reply_kb"' /var/lib/pi-gateway/telegram-status-card.json 2>/dev/null; then
  curl -fsS -X POST "${API}/sendMessage" \
    -d "chat_id=${TELEGRAM_CHAT_ID}" \
    -d 'reply_markup={"remove_keyboard":true}' \
    -d "disable_notification=true" \
    -d "text= " >/dev/null 2>&1 || true
  python3 - <<'PY' 2>/dev/null || true
import json
from pathlib import Path
p = Path("/var/lib/pi-gateway/telegram-status-card.json")
if p.is_file():
    d = json.loads(p.read_text(encoding="utf-8"))
    d.pop("reply_kb", None)
    p.write_text(json.dumps(d, indent=2) + "\n", encoding="utf-8")
PY
fi

log "Durum karti guncellendi"
