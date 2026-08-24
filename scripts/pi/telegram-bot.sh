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
if [[ "${HERMES_TELEGRAM_GATEWAY:-}" == "true" ]] \
  || systemctl is-active --quiet hermes-gateway 2>/dev/null; then
  log "Hermes gateway aktif — panel poller calismaz (getUpdates tek sahip)"
  exit 0
fi
load_telegram_from_hermes || true
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
export AGH_ADMIN_USER CADDY_AUTH_USER FORGEJO_ADMIN_USER FORGEJO_LOGIN_USER
export HERMES_TELEGRAM_GATEWAY
export DOZZLE_PORT ADGUARD_WEB_PORT FORGEJO_PORT N8N_PORT SYNCTHING_PORT GRAFANA_PORT NETALERTX_PORT
resolve_tailscale_url() {
  # Legacy MagicDNS URL — panels artık TS IP:PORT kullanır; env yalnız geriye uyum
  if [[ -n "${TAILSCALE_PANEL_URL:-}" ]]; then
    return 0
  fi
  if [[ -f /var/lib/pi-gateway/tailscale-panel-url ]]; then
    TAILSCALE_PANEL_URL="$(cat /var/lib/pi-gateway/tailscale-panel-url 2>/dev/null || true)"
    export TAILSCALE_PANEL_URL
  fi
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
    --data-urlencode "text=Paneller — /menu" \
    -d "parse_mode=HTML" \
    -d "disable_web_page_preview=true" \
    --data-urlencode "reply_markup=${reply}"
}
tg_remove_reply_keyboard() {
  local chat_id="$1"
  tg_api sendMessage \
    -d "chat_id=${chat_id}" \
    --data-urlencode "text=Sohbet = Hermes · paneller = sabitli mesaj" \
    -d "parse_mode=HTML" \
    -d "disable_web_page_preview=true" \
    --data-urlencode 'reply_markup={"remove_keyboard":true}'
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
  local inline reply text use_reply resp msg_id webapp
  inline="$(python3 "$PANELS_PY" keyboard "$sub")"
  text="$(python3 "$PANELS_PY" text "$sub")"
  resp="$(tg_api_json sendMessage \
    -d "chat_id=${chat_id}" \
    --data-urlencode "text=${text}" \
    -d "parse_mode=HTML" \
    -d "disable_web_page_preview=true" \
    --data-urlencode "reply_markup=${inline}" 2>/dev/null || true)"
  msg_id="$(printf '%s' "$resp" | python3 -c "import json,sys; print(json.load(sys.stdin).get('result',{}).get('message_id',''))" 2>/dev/null || true)"
  if [[ -n "$msg_id" ]]; then
    tg_api pinChatMessage \
      -d "chat_id=${chat_id}" \
      -d "message_id=${msg_id}" \
      -d "disable_notification=true" >/dev/null 2>&1 || true
  fi
  webapp="$(python3 "$PANELS_PY" menu_webapp_url 2>/dev/null || true)"
  if [[ -n "$webapp" ]]; then
    tg_api setChatMenuButton \
      -d "chat_id=${chat_id}" \
      --data-urlencode "menu_button={\"type\":\"web_app\",\"text\":\"Paneller\",\"web_app\":{\"url\":\"${webapp}/\"}}" \
      >/dev/null 2>&1 || true
  else
    tg_api setChatMenuButton \
      -d "chat_id=${chat_id}" \
      -d 'menu_button={"type":"commands"}' \
      >/dev/null 2>&1 || true
  fi
  use_reply="$(python3 "$PANELS_PY" use_reply_keyboard 2>/dev/null || echo 1)"
  if [[ "$use_reply" == "1" ]]; then
    reply="$(python3 "$PANELS_PY" reply_keyboard)"
    tg_send_reply_keyboard "$chat_id" "$reply"
  else
    tg_remove_reply_keyboard "$chat_id"
  fi
}
register_bot_ui() {
  tg_api setMyCommands \
    -d 'commands=[{"command":"menu","description":"Panel menusu (sabitle)"},{"command":"paneller","description":"Panel menusu"}]' \
    >/dev/null 2>&1 || true
  tg_api setMyDescription \
    --data-urlencode "description=Pi Gateway paneller — /menu. Sohbet Hermes." \
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
    /start|/menu|/paneller|/linkler|Paneller|menu|paneller|linkler)
      send_panel_menu "$chat_id" all
      ;;
    /uzak|/remote|uzak)
      send_panel_menu "$chat_id" remote
      ;;
    /ev|/home|ev)
      send_panel_menu "$chat_id" home
      ;;
    /help|help)
      tg_send_text "$chat_id" "<b>Pi Gateway</b>\n\n/menu veya /paneller — panel menüsü (sabitlenir)\nButon → Safari’de Aç\n\n<i>Sohbet = Hermes · uyarılar = otomatik bildirimler</i>"
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
