#!/usr/bin/env bash
# Pi Gateway → OpenBot Jarvis uyarı köprüsü (workflow/routine webhook).
set -euo pipefail

_openbot_jarvis_send_script() {
  local self_dir pg cand
  self_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
  pg="${REMOTE_DIR:-${HOME}/pi-gateway}"
  # Root systemd birimlerinde root-owned kopya once (trust boundary)
  if [[ "$(id -u)" -eq 0 ]]; then
    cand="${self_dir}/../pi/jarvis-send.sh"
    [[ -x "$cand" ]] && { printf '%s' "$cand"; return 0; }
    return 1
  fi
  for cand in "${pg}/scripts/pi/jarvis-send.sh" "${self_dir}/../pi/jarvis-send.sh"; do
    [[ -x "$cand" ]] && { printf '%s' "$cand"; return 0; }
  done
  return 1
}

openbot_notify_enabled() {
  if [[ "${OPENBOT_JARVIS_AUTOMATION:-}" == "true" ]] && _openbot_jarvis_send_script >/dev/null 2>&1; then
    return 0
  fi
  [[ -n "${OPENBOT_ALERT_WEBHOOK_URL:-}" ]]
}

# HTML → Heimdall kartı. Emoji başlık ve "Ne yapmalı?" Telegram kalıntısı burada biter.
openbot_notify_plaintext() {
  local raw="$1"
  printf '%s' "$raw" | python3 -c '
import re, sys
raw = sys.stdin.read()
raw = re.sub(r"(?i)<br\s*/?>", "\n", raw)
raw = re.sub(r"(?i)</p>", "\n", raw)
raw = re.sub(r"<[^>]+>", "", raw)
raw = (raw.replace("&amp;", "&").replace("&lt;", "<")
       .replace("&gt;", ">").replace("&#39;", "\u0027").replace("&quot;", "\""))
lines = [ln.rstrip() for ln in raw.strip().splitlines()]
while lines and not lines[0].strip():
    lines.pop(0)
if not lines:
    print("Heimdall · durum\nBoş bildirim")
    raise SystemExit(0)
title = re.sub(r"^[^\wÇĞİÖŞÜçğıöşü]+", "", lines[0].strip())
body = "\n".join(lines[1:]).strip().replace("Ne yapmalı?", "Sonraki")
low = title.casefold()
kind = "uyarı"
if any(w in low for w in ("normale", "döndü", "tamamlandı", "güncel", "aktif", "stabil", "düzeldi")):
    kind = "durum"
out = f"Heimdall · {kind}\n{title}"
if body:
    out += "\n\n" + body
print(out)
'
}

# POST JSON: { "type": "pi-gateway.alert", "data": { "title", "body", "source" } }
openbot_notify_send() {
  local text="$1"
  local parse_mode="${2:-}"
  local body plain title
  local pg="${REMOTE_DIR:-${HOME}/pi-gateway}"
  local js_path=""
  js_path="$(_openbot_jarvis_send_script 2>/dev/null || true)"
  if [[ "${OPENBOT_JARVIS_AUTOMATION:-}" == "true" && -n "$js_path" ]]; then
    if [[ "$parse_mode" == "HTML" ]]; then
      plain="$(openbot_notify_plaintext "$text")"
    else
      plain="$text"
    fi
    local js=( "$js_path" )
    # Varsayılan: kuyruğa bırak (202). Timer birimleri LLM turunu bekleyemez.
    if [[ "${OPENBOT_JARVIS_WAIT_DELIVERY:-false}" == "true" ]]; then
      js+=( --wait --timeout "${OPENBOT_ALERT_WAIT_SEC:-120}" )
    fi
    REMOTE_DIR="$pg" OPENBOT_ALERT_WAIT_SEC="${OPENBOT_ALERT_WAIT_SEC:-120}" \
      bash "${js[@]}" "$plain" && return 0
    return 1
  fi
  [[ -n "${OPENBOT_ALERT_WEBHOOK_URL:-}" ]] || return 1
  if [[ "$parse_mode" == "HTML" ]]; then
    plain="$(openbot_notify_plaintext "$text")"
  else
    plain="$text"
  fi
  title="$(printf '%s\n' "$plain" | head -n1 | cut -c1-120)"
  body="$plain"
  local payload
  payload="$(OPENBOT_TITLE="$title" OPENBOT_BODY="$body" OPENBOT_SOURCE="${OPENBOT_ALERT_SOURCE:-pi-gateway}" \
    python3 - <<'PY'
import json, os
print(json.dumps({
    "type": "pi-gateway.alert",
    "data": {
        "title": os.environ.get("OPENBOT_TITLE", "Pi Gateway"),
        "body": os.environ.get("OPENBOT_BODY", ""),
        "source": os.environ.get("OPENBOT_SOURCE", "pi-gateway"),
    },
}, ensure_ascii=False))
PY
)"
  local curl_args=(
    -fsS --connect-timeout 5 --max-time 30
    -X POST
    -H "Content-Type: application/json"
    --data-binary "$payload"
  )
  if [[ -n "${OPENBOT_ALERT_WEBHOOK_SECRET:-}" ]]; then
    curl_args+=(-H "X-OpenBot-Webhook-Secret: ${OPENBOT_ALERT_WEBHOOK_SECRET}")
  fi
  curl "${curl_args[@]}" "${OPENBOT_ALERT_WEBHOOK_URL}" >/dev/null
}