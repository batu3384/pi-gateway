#!/usr/bin/env bash
# Uptime Kuma monitorlerini otomatik ekler
set -euo pipefail

REMOTE_DIR="${REMOTE_DIR:-/home/${USER}/pi-gateway}"
# shellcheck source=/dev/null
[[ -f "$REMOTE_DIR/.env" ]] && source "$REMOTE_DIR/.env"

KUMA_URL="${UPTIME_KUMA_URL:-http://127.0.0.1:3001}"
KUMA_USER="${UPTIME_KUMA_ADMIN_USER:-batu}"
KUMA_PASS="${UPTIME_KUMA_ADMIN_PASSWORD:-}"
PI_IP="${PI_STATIC_IP:-192.168.1.112}"

log() { echo "[uptime-kuma-setup] $*"; }

[[ -n "$KUMA_PASS" ]] || { log "UPTIME_KUMA_ADMIN_PASSWORD bos — atlandi"; exit 0; }

docker ps --format '{{.Names}}' | grep -q '^uptime-kuma$' || { log "uptime-kuma container yok"; exit 1; }

sync_password() {
  local hash
  hash="$(docker exec uptime-kuma node -e "const b=require('bcryptjs'); console.log(b.hashSync(process.argv[1], 10));" "$KUMA_PASS")"
  docker exec uptime-kuma sqlite3 /app/data/kuma.db \
    "UPDATE user SET password='${hash}' WHERE username='${KUMA_USER}';"
  log "Kullanici sifresi guncellendi: ${KUMA_USER}"
}

sync_password

DOCKER_GW="${DOCKER_GATEWAY:-172.18.0.1}"
export KUMA_URL KUMA_USER KUMA_PASS PI_IP DOCKER_GW
export TELEGRAM_BOT_TOKEN="${TELEGRAM_BOT_TOKEN:-}"
export TELEGRAM_CHAT_ID="${TELEGRAM_CHAT_ID:-}"
export UPTIME_KUMA_STATUS_SLUG="${UPTIME_KUMA_STATUS_SLUG:-pi-gateway}"

docker run --rm --network host \
  -e KUMA_URL -e KUMA_USER -e KUMA_PASS -e PI_IP -e DOCKER_GW \
  -e TELEGRAM_BOT_TOKEN -e TELEGRAM_CHAT_ID -e UPTIME_KUMA_STATUS_SLUG \
  python:3.12-alpine sh -c '
    pip install -q uptime-kuma-api2
    python - <<'"'"'PY'"'"'
import os
from uptime_kuma_api import UptimeKumaApi, MonitorType

url = os.environ["KUMA_URL"]
user = os.environ["KUMA_USER"]
password = os.environ["KUMA_PASS"]
pi_ip = os.environ["PI_IP"]
gw = os.environ["DOCKER_GW"]
tg_token = os.environ.get("TELEGRAM_BOT_TOKEN", "")
tg_chat = os.environ.get("TELEGRAM_CHAT_ID", "")

ok = ["200-299", "301", "302", "401"]

monitors = [
    ("Pi Gateway", MonitorType.PING, {"hostname": pi_ip}),
    ("Homepage", MonitorType.HTTP, {"url": "http://homepage:3000", "accepted_statuscodes": ok}),
    ("AdGuard", MonitorType.HTTP, {"url": f"http://{gw}:8080", "accepted_statuscodes": ok}),
    ("Caddy", MonitorType.HTTP, {"url": "http://caddy:80", "accepted_statuscodes": ok}),
    ("logs.home", MonitorType.HTTP, {
        "url": f"http://{pi_ip}",
        "headers": "Host: logs.home",
        "accepted_statuscodes": ok,
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

if tg_token and tg_chat:
    existing = {n.get("name") for n in api.get_notifications()}
    if "Telegram" not in existing:
        api.add_notification({
            "name": "Telegram",
            "type": "telegram",
            "isDefault": True,
            "applyExisting": True,
            "telegramBotToken": tg_token,
            "telegramChatID": tg_chat,
        })
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
