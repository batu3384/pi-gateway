#!/usr/bin/env bash
# Telegram bot: /menu + kalici klavye + acilir panel linkleri
set -euo pipefail
REMOTE_DIR="${REMOTE_DIR:-/home/${USER}/pi-gateway}"
STATE_DIR="${TELEGRAM_BOT_STATE_DIR:-/var/lib/pi-gateway/telegram-bot-state}"
OFFSET_FILE="${STATE_DIR}/offset"
PANELS_PY="${REMOTE_DIR}/scripts/lib/telegram-panels.py"
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
_PG_ENV_LIB="${SCRIPT_DIR:-$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)}/../lib/env-file.sh"
PG_SCRIPT_NAME="$(basename "$0")"
# shellcheck source=../lib/env-file.sh
source "${_PG_ENV_LIB:?}"
read_remote_dotenv || { echo "[${PG_SCRIPT_NAME:-script}] HATA: .env dotenv parser hatasi" >&2; exit 1; }
log() { echo "[telegram-bot] $*"; }
[[ -n "${TELEGRAM_BOT_TOKEN:-}" && -n "${TELEGRAM_CHAT_ID:-}" ]] || {
  log "TELEGRAM_BOT_TOKEN / TELEGRAM_CHAT_ID eksik"
  exit 1
}
[[ -f "$PANELS_PY" ]] || { log "HATA: telegram-panels.py yok"; exit 1; }
if ! mkdir -p "$STATE_DIR" 2>/dev/null; then
  sudo mkdir -p "$STATE_DIR" 2>/dev/null || true
  sudo chown "${USER}:${USER}" "$STATE_DIR" 2>/dev/null || true
fi
chmod 700 "$STATE_DIR" 2>/dev/null || true
export LAN_DOMAIN PI_STATIC_IP PANEL_PROTOCOL ENABLE_TLS TAILSCALE_PANEL_URL
resolve_tailscale_url() {
  if [[ -n "${TAILSCALE_PANEL_URL:-}" ]]; then
    return 0
  fi
  if [[ -f /var/lib/pi-gateway/tailscale-panel-url ]]; then
    TAILSCALE_PANEL_URL="$(cat /var/lib/pi-gateway/tailscale-panel-url 2>/dev/null || true)"
    export TAILSCALE_PANEL_URL
    [[ -n "$TAILSCALE_PANEL_URL" ]] && return 0
  fi
  command -v tailscale >/dev/null 2>&1 || return 0
  TAILSCALE_PANEL_URL="$(tailscale status --json 2>/dev/null | python3 -c "
import json,sys
d=json.load(sys.stdin).get('Self',{}).get('DNSName','').rstrip('.')
print(f'https://{d}' if d else '')
" 2>/dev/null || true)"
  export TAILSCALE_PANEL_URL
}
resolve_tailscale_url
tg_api() {
  local method="$1"
  shift
  # stdout journal'a dusmesin (PII / buyuk JSON)
  curl -fsS -o /dev/null -X POST "https://api.telegram.org/bot${TELEGRAM_BOT_TOKEN}/${method}" "$@"
}
tg_api_json() {
  local method="$1"
  shift
  curl -fsS -X POST "https://api.telegram.org/bot${TELEGRAM_BOT_TOKEN}/${method}" "$@"
}
# Telegram tek reply_markup kabul eder — inline + kalici klavye = 2 mesaj
tg_send_inline() {
  local chat_id="$1"
  local text="$2"
  local inline="$3"
  tg_api sendMessage \
    -d "chat_id=${chat_id}" \
    --data-urlencode "text=${text}" \
    -d "parse_mode=HTML" \
    -d "disable_web_page_preview=true" \
    --data-urlencode "reply_markup=${inline}"
}
tg_send_reply_keyboard() {
  local chat_id="$1"
  local reply="$2"
  tg_api sendMessage \
    -d "chat_id=${chat_id}" \
    --data-urlencode "text=⌨️ <b>Hizli erisim</b> — alttaki butonlar kalici. /menu = yenile." \
    -d "parse_mode=HTML" \
    -d "disable_web_page_preview=true" \
    --data-urlencode "reply_markup=${reply}"
}
tg_send_text() {
  local chat_id="$1"
  local text="$2"
  tg_api sendMessage \
    -d "chat_id=${chat_id}" \
    --data-urlencode "text=${text}" \
    -d "parse_mode=HTML" \
    -d "disable_web_page_preview=true"
}
send_panel_menu() {
  local chat_id="$1"
  local sub="${2:-all}"
  local inline reply text
  inline="$(python3 "$PANELS_PY" keyboard "$sub")"
  reply="$(python3 "$PANELS_PY" reply_keyboard)"
  text="$(python3 "$PANELS_PY" text "$sub")"
  tg_send_inline "$chat_id" "$text" "$inline"
  tg_send_reply_keyboard "$chat_id" "$reply"
}
register_bot_ui() {
  tg_api setMyCommands \
    -d 'commands=[{"command":"menu","description":"Tum panel linkleri"},{"command":"paneller","description":"Panel menusu"},{"command":"uzak","description":"Tailscale HTTPS linkler"},{"command":"ev","description":"Ev agi linkler"},{"command":"ip","description":"IP yedek linkler"}]' \
    >/dev/null 2>&1 || true
  tg_api setMyDescription \
    --data-urlencode "description=Pi Gateway panel botu. /menu veya 📋 Tüm paneller — linkler altta kalici." \
    >/dev/null 2>&1 || true
  tg_api setChatMenuButton \
    -d "chat_id=${TELEGRAM_CHAT_ID}" \
    -d 'menu_button={"type":"commands"}' \
    >/dev/null 2>&1 || true
}
handle_message() {
  local chat_id="$1"
  local text="$2"
  case "$text" in
    /start|/menu|/paneller|/linkler|"📋 Tüm paneller"|menu|paneller|linkler)
      send_panel_menu "$chat_id" all
      ;;
    /uzak|/remote|"🌐 Uzaktan (Tailscale)"|"🌐 Uzaktan (HTTPS)"|uzak)
      mode="$(python3 "$PANELS_PY" remote_mode 2>/dev/null || echo none)"
      if [[ "$mode" == "serve" ]]; then
        send_panel_menu "$chat_id" remote
      elif [[ -n "$(tailscale ip -4 2>/dev/null | head -1)" ]]; then
        send_panel_menu "$chat_id" remote
      else
        tg_send_text "$chat_id" "⚠️ Tailscale yok.\n\n<code>bash scripts/pi/setup-tailscale-serve.sh</code>"
      fi
      ;;
    /ev|/home|"🏠 Ev ağı"|ev)
      send_panel_menu "$chat_id" home
      ;;
    /ip|"📍 IP yedek"|ip)
      send_panel_menu "$chat_id" ip
      ;;
    /help|help)
      tg_send_text "$chat_id" "Komutlar: /menu /uzak /ev /ip\nveya alttaki kalici butonlar."
      ;;
    *)
      log "yok sayilan metin (${#text} char)"
      ;;
  esac
}
poll_once() {
  local offset resp
  offset="$(cat "$OFFSET_FILE" 2>/dev/null || echo 0)"
  resp="$(tg_api_json getUpdates -d "offset=${offset}" -d "timeout=25" -d 'allowed_updates=["message"]' 2>/dev/null || true)"
  [[ -n "$resp" ]] || return 0
  python3 - "$resp" "$TELEGRAM_CHAT_ID" <<'PY' | while IFS=$'\t' read -r next_offset chat_id text; do
import json, sys
data = json.loads(sys.argv[1])
for u in data.get("result", []):
    uid = u["update_id"]
    msg = u.get("message") or {}
    chat = msg.get("chat") or {}
    cid = str(chat.get("id", ""))
    text = (msg.get("text") or "").strip()
    print(f"{uid + 1}\t{cid}\t{text}")
PY
    [[ -n "$next_offset" ]] && echo "$next_offset" > "$OFFSET_FILE"
    [[ -z "$chat_id" || -z "$text" ]] && continue
    if [[ "$chat_id" == "$TELEGRAM_CHAT_ID" ]]; then
      handle_message "$chat_id" "$text"
    else
      log "yok sayilan chat_id=${chat_id:0:4}…"
    fi
  done
}
main_loop() {
  log "basladi (chat=${TELEGRAM_CHAT_ID})"
  register_bot_ui
  send_panel_menu "$TELEGRAM_CHAT_ID" all
  while true; do
    poll_once || sleep 2
  done
}
if [[ "${1:-}" == "--once" ]]; then
  register_bot_ui
  send_panel_menu "$TELEGRAM_CHAT_ID" all
  exit 0
fi
if [[ "${1:-}" == "--poll" ]]; then
  poll_once
  exit 0
fi
main_loop
