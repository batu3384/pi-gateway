#!/usr/bin/env bash
# Telegram: panel menüsü (pin + tek sütun URL + Paneller reply keyboard)
set -euo pipefail
REMOTE_DIR="${REMOTE_DIR:-/home/${USER}/pi-gateway}"
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PANELS_PY="${REMOTE_DIR}/scripts/lib/telegram-panels.py"
_PG_ENV_LIB="${SCRIPT_DIR}/../lib/env-file.sh"
PG_SCRIPT_NAME="$(basename "$0")"
# shellcheck source=../lib/env-file.sh
source "${_PG_ENV_LIB:?}"
read_remote_dotenv || { echo "[${PG_SCRIPT_NAME}] HATA: .env dotenv parser hatasi" >&2; exit 1; }
load_telegram_from_hermes || true
source "$SCRIPT_DIR/../lib/notify.sh"
log() { echo "[telegram-menu] $*"; }
notify_enabled || { log "TELEGRAM_BOT_TOKEN / TELEGRAM_CHAT_ID eksik"; exit 1; }
[[ -f "$PANELS_PY" ]] || { log "HATA: telegram-panels.py yok"; exit 1; }

# Ensure TS :PORT DNAT before advertising links
if [[ -x "$REMOTE_DIR/scripts/pi/setup-tailscale-panel-ports.sh" ]]; then
  bash "$REMOTE_DIR/scripts/pi/setup-tailscale-panel-ports.sh" || log "WARN: ts-panel-ports"
fi

export LAN_DOMAIN PI_STATIC_IP PANEL_PROTOCOL ENABLE_TLS
export AGH_ADMIN_USER CADDY_AUTH_USER
export HERMES_TELEGRAM_GATEWAY
export DOZZLE_PORT ADGUARD_WEB_PORT N8N_PORT GRAFANA_PORT NETALERTX_PORT

API="https://api.telegram.org/bot${TELEGRAM_BOT_TOKEN}"
MARKUP="$(python3 "$PANELS_PY" keyboard all)"
TEXT="$(python3 "$PANELS_PY" text all)"

resp="$(curl -fsS -X POST "${API}/sendMessage" \
  -d "chat_id=${TELEGRAM_CHAT_ID}" \
  -d "parse_mode=HTML" \
  --data-urlencode "text=${TEXT}" \
  --data-urlencode "reply_markup=${MARKUP}" \
  -d "disable_web_page_preview=true")"

msg_id="$(printf '%s' "$resp" | python3 -c "import json,sys; print(json.load(sys.stdin).get('result',{}).get('message_id',''))" 2>/dev/null || true)"
if [[ -n "$msg_id" ]]; then
  curl -fsS -X POST "${API}/pinChatMessage" \
    -d "chat_id=${TELEGRAM_CHAT_ID}" \
    -d "message_id=${msg_id}" \
    -d "disable_notification=true" >/dev/null 2>&1 || true
fi

curl -fsS -X POST "${API}/setChatMenuButton" \
  -d "chat_id=${TELEGRAM_CHAT_ID}" \
  -d 'menu_button={"type":"commands"}' >/dev/null 2>&1 || true

# Hermes owns global setMyCommands (60+ core → skill /menu menüye sığmaz).
# Bu chat için daha dar scope: menu/paneller önde, mevcut liste korunur.
_register_chat_panel_commands() {
  python3 - "$API" "$TELEGRAM_CHAT_ID" <<'PY'
import json, sys, urllib.parse, urllib.request

api, chat_id = sys.argv[1], sys.argv[2]
want = [
    ("menu", "Panel menusu (sabitle)"),
    ("paneller", "Panel menusu"),
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
  _register_chat_panel_commands || log "WARN: chat-scope /menu komutlari"
else
  curl -fsS -X POST "${API}/setMyCommands" \
    -d 'commands=[{"command":"menu","description":"Panel menusu (sabitle)"},{"command":"paneller","description":"Panel menusu"}]' \
    >/dev/null 2>&1 || true
fi

# Paneller sticky reply — Hermes skill "Paneller" / /menu yakalar
REPLY="$(python3 "$PANELS_PY" reply_keyboard)"
curl -fsS -X POST "${API}/sendMessage" \
  -d "chat_id=${TELEGRAM_CHAT_ID}" \
  -d "parse_mode=HTML" \
  --data-urlencode "text=Paneller — /menu" \
  --data-urlencode "reply_markup=${REPLY}" \
  -d "disable_web_page_preview=true" >/dev/null

log "Menü gönderildi"
