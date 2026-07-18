#!/usr/bin/env bash
# shellcheck disable=SC1083
# Uptime Kuma: DB kurulumu, admin, monitorler
set -euo pipefail

REMOTE_DIR="${REMOTE_DIR:-/home/${USER}/pi-gateway}"
# shellcheck source=/dev/null
[[ -f "$REMOTE_DIR/.env" ]] && source "$REMOTE_DIR/.env"

KUMA_URL="${UPTIME_KUMA_URL:-http://127.0.0.1:3001}"
KUMA_USER="${UPTIME_KUMA_ADMIN_USER:-batu}"
KUMA_PASS="${UPTIME_KUMA_ADMIN_PASSWORD:-}"
PI_IP="${PI_STATIC_IP:-192.168.1.112}"
export KUMA_URL KUMA_USER KUMA_PASS

log() { echo "[uptime-kuma-setup] $*"; }

[[ -n "$KUMA_PASS" ]] || { log "HATA: UPTIME_KUMA_ADMIN_PASSWORD bos"; exit 1; }
case "$KUMA_PASS" in
  CHANGE_ME*|Degistir*) log "HATA: UPTIME_KUMA_ADMIN_PASSWORD placeholder"; exit 1 ;;
esac

docker ps --format '{{.Names}}' | grep -q '^uptime-kuma$' || { log "uptime-kuma container yok"; exit 1; }

wait_for_kuma_http() {
  local i
  for i in $(seq 1 40); do
    if curl -fsS "${KUMA_URL}/api/entry-page" >/dev/null 2>&1 \
      || curl -fsS "${KUMA_URL}/setup-database-info" >/dev/null 2>&1; then
      return 0
    fi
    sleep 3
  done
  log "HATA: uptime-kuma HTTP hazir degil"
  return 1
}

ensure_kuma_database() {
  local info
  info="$(curl -fsS "${KUMA_URL}/setup-database-info" 2>/dev/null || true)"
  if ! echo "$info" | grep -q '"needSetup":true'; then
    return 0
  fi
  log "SQLite veritabani kuruluyor (setup-database)..."
  curl -fsS -X POST "${KUMA_URL}/setup-database" \
    -H "Content-Type: application/json" \
    -d '{"dbConfig":{"type":"sqlite"}}' >/dev/null
  docker restart uptime-kuma >/dev/null
  wait_for_kuma_http
}

sync_password_sqlite() {
  local hash
  hash="$(docker exec uptime-kuma node -e "const b=require('bcryptjs'); console.log(b.hashSync(process.argv[1], 10));" "$KUMA_PASS")"
  if docker exec uptime-kuma sqlite3 /app/data/kuma.db \
    "SELECT COUNT(*) FROM user WHERE username='${KUMA_USER}';" 2>/dev/null | grep -q '^1$'; then
    docker exec uptime-kuma sqlite3 /app/data/kuma.db \
      "UPDATE user SET password='${hash}' WHERE username='${KUMA_USER}';"
    log "Kullanici sifresi guncellendi (sqlite): ${KUMA_USER}"
  fi
}

ensure_kuma_admin() {
  docker run --rm --network host \
    -e KUMA_URL -e KUMA_USER -e KUMA_PASS \
    python:3.12-alpine sh -c '
      pip install -q uptime-kuma-api2
      python - <<'"'"'PY'"'"'
import os, sys
from uptime_kuma_api import UptimeKumaApi

url = os.environ["KUMA_URL"]
user = os.environ["KUMA_USER"]
password = os.environ["KUMA_PASS"]
api = UptimeKumaApi(url, timeout=60)
try:
    if api.need_setup():
        api.setup(user, password)
        print("admin-setup-ok")
    else:
        api.login(user, password)
        print("admin-login-ok")
except Exception as exc:
    print(f"admin-fail: {exc}", file=sys.stderr)
    sys.exit(1)
finally:
    api.disconnect()
PY
    ' || {
    log "API login/setup basarisiz — sqlite sifre senkronu deneniyor"
    sync_password_sqlite
    docker run --rm --network host \
      -e KUMA_URL -e KUMA_USER -e KUMA_PASS \
      python:3.12-alpine sh -c '
        pip install -q uptime-kuma-api2
        python - <<'"'"'PY'"'"'
import os
from uptime_kuma_api import UptimeKumaApi
api = UptimeKumaApi(os.environ["KUMA_URL"], timeout=60)
api.login(os.environ["KUMA_USER"], os.environ["KUMA_PASS"])
print("admin-login-ok-retry")
api.disconnect()
PY
      '
  }
}

wait_for_kuma_http
ensure_kuma_database
ensure_kuma_admin

DOCKER_GW="${DOCKER_GATEWAY:-172.18.0.1}"
export KUMA_URL KUMA_USER KUMA_PASS PI_IP DOCKER_GW LAN_DOMAIN
export TELEGRAM_BOT_TOKEN="${TELEGRAM_BOT_TOKEN:-}"
export TELEGRAM_CHAT_ID="${TELEGRAM_CHAT_ID:-}"
export UPTIME_KUMA_STATUS_SLUG="${UPTIME_KUMA_STATUS_SLUG:-pi-gateway}"
export ENABLE_N8N="${ENABLE_N8N:-true}"
export LAN_DOMAIN="${LAN_DOMAIN:-home}"
if [[ -n "${N8N_KUMA_WEBHOOK_URL:-}" ]]; then
  :
else
  secret="${N8N_WEBHOOK_SECRET:-}"
  case "$secret" in
    ""|CHANGE_ME*) log "HATA: N8N_WEBHOOK_SECRET gerekli"; exit 1 ;;
  esac
  N8N_KUMA_WEBHOOK_URL="http://n8n:5678/webhook/uptime-kuma-alert-${secret}"
fi
export N8N_KUMA_WEBHOOK_URL

docker run --rm --network host \
  -e KUMA_URL -e KUMA_USER -e KUMA_PASS -e PI_IP -e DOCKER_GW -e LAN_DOMAIN \
  -e TELEGRAM_BOT_TOKEN -e TELEGRAM_CHAT_ID -e UPTIME_KUMA_STATUS_SLUG \
  -e ENABLE_N8N -e N8N_KUMA_WEBHOOK_URL \
  python:3.12-alpine sh -c '
    pip install -q uptime-kuma-api2
    python - <<'"'"'PY'"'"'
import os
import json
from uptime_kuma_api import UptimeKumaApi, MonitorType

url = os.environ["KUMA_URL"]
user = os.environ["KUMA_USER"]
password = os.environ["KUMA_PASS"]
pi_ip = os.environ["PI_IP"]
gw = os.environ["DOCKER_GW"]
lan = os.environ.get("LAN_DOMAIN", "home")
tg_token = os.environ.get("TELEGRAM_BOT_TOKEN", "")
tg_chat = os.environ.get("TELEGRAM_CHAT_ID", "")

ok = ["200-299", "301", "302", "307", "308", "401"]

monitors = [
    ("Pi Gateway", MonitorType.PING, {"hostname": pi_ip}),
    ("Homepage", MonitorType.HTTP, {"url": "http://homepage:3000", "accepted_statuscodes": ok}),
    ("AdGuard", MonitorType.HTTP, {"url": f"http://{gw}:8080", "accepted_statuscodes": ok}),
    ("Caddy", MonitorType.HTTP, {
        "url": "https://caddy:443",
        "headers": json.dumps({"Host": f"gateway.{lan}"}),
        "accepted_statuscodes": ok,
        "ignoreTls": True,
        "maxredirects": 0,
    }),
    (f"logs.{lan}", MonitorType.HTTP, {
        "url": f"https://logs.{lan}",
        "accepted_statuscodes": ok,
        "ignoreTls": True,
        "maxredirects": 0,
    }),
    ("Forgejo", MonitorType.HTTP, {"url": "http://forgejo:3000", "accepted_statuscodes": ok}),
    ("Syncthing", MonitorType.HTTP, {"url": "http://syncthing:8384", "accepted_statuscodes": ok}),
    ("n8n", MonitorType.HTTP, {"url": "http://n8n:5678", "accepted_statuscodes": ok}),
    ("Dozzle", MonitorType.HTTP, {"url": "http://dozzle:8080", "accepted_statuscodes": ok}),
    ("Uptime Kuma", MonitorType.HTTP, {"url": "http://127.0.0.1:3001", "accepted_statuscodes": ok}),
    ("Unbound DNS", MonitorType.PORT, {"hostname": "unbound", "port": 5335}),
    ("Redis", MonitorType.PORT, {"hostname": "redis", "port": 6379}),
]

api = UptimeKumaApi(url, timeout=30)
api.login(user, password)

status_slug = os.environ.get("UPTIME_KUMA_STATUS_SLUG", "pi-gateway")
pages = {p.get("slug"): p for p in api.get_status_pages()}
if status_slug not in pages:
    api.add_status_page(slug=status_slug, title="Pi Gateway")
    print(f"status-page: {status_slug} eklendi")
else:
    print(f"status-page: {status_slug} zaten var")

use_n8n = os.environ.get("ENABLE_N8N", "true") == "true"
n8n_hook = os.environ.get("N8N_KUMA_WEBHOOK_URL", "http://n8n:5678/webhook/uptime-kuma-alert")
existing = {n.get("name") for n in api.get_notifications()}

if use_n8n:
    if "n8n Webhook" not in existing:
        api.add_notification(
            name="n8n Webhook",
            type="webhook",
            isDefault=True,
            applyExisting=True,
            webhookURL=n8n_hook,
            webhookContentType="application/json",
        )
        print(f"notification: n8n Webhook eklendi ({n8n_hook})")
    else:
        notifs = {n.get("name"): n for n in api.get_notifications()}
        nid = notifs.get("n8n Webhook", {}).get("id")
        if nid:
            api.edit_notification(
                nid,
                name="n8n Webhook",
                type="webhook",
                isDefault=True,
                applyExisting=True,
                webhookURL=n8n_hook,
                webhookContentType="application/json",
            )
            print(f"notification: n8n Webhook guncellendi ({n8n_hook})")
        else:
            print("notification: n8n Webhook zaten var")
elif tg_token and tg_chat:
    if "Telegram" not in existing:
        api.add_notification(
            name="Telegram",
            type="telegram",
            isDefault=True,
            applyExisting=True,
            telegramBotToken=tg_token,
            telegramChatID=tg_chat,
        )
        print("notification: Telegram eklendi")
    else:
        print("notification: Telegram zaten var")

by_name = {m.get("name"): m for m in api.get_monitors() if m.get("type") != "group"}
updated = added = 0
for name, mtype, kwargs in monitors:
    base = {"type": mtype, "name": name, "interval": 60, "maxretries": 2, "conditions": [], **kwargs}
    if name in by_name:
        mid = by_name[name]["id"]
        api.edit_monitor(mid, **{k: v for k, v in base.items() if k != "id"})
        print(f"updated: {name}")
        updated += 1
    else:
        api.add_monitor(**base)
        print(f"added: {name}")
        added += 1
api.disconnect()
print(f"done: {added} yeni, {updated} guncellendi")
PY
  '

log "Tamamlandi — ${KUMA_URL}"
