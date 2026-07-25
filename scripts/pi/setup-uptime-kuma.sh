#!/usr/bin/env bash
# shellcheck disable=SC1083
# Uptime Kuma: DB kurulumu, admin, monitorler
set -euo pipefail

REMOTE_DIR="${REMOTE_DIR:-/home/${USER}/pi-gateway}"
# shellcheck source=/dev/null
[[ -f "$REMOTE_DIR/.env" ]] && source "$REMOTE_DIR/.env"

KUMA_URL="${UPTIME_KUMA_URL:-http://127.0.0.1:3001}"
KUMA_USER="${UPTIME_KUMA_ADMIN_USER:-admin}"
KUMA_PASS="${UPTIME_KUMA_ADMIN_PASSWORD:-}"
PI_IP="${PI_STATIC_IP:-}"
export KUMA_URL KUMA_USER KUMA_PASS

log() { echo "[uptime-kuma-setup] $*"; }

[[ -n "$PI_IP" ]] || { log "HATA: PI_STATIC_IP bos"; exit 1; }
[[ -n "$KUMA_PASS" ]] || { log "HATA: UPTIME_KUMA_ADMIN_PASSWORD bos"; exit 1; }
case "$KUMA_PASS" in
  CHANGE_ME*|Degistir*) log "HATA: UPTIME_KUMA_ADMIN_PASSWORD placeholder"; exit 1 ;;
esac

docker ps --format '{{.Names}}' | grep -q '^uptime-kuma$' || { log "uptime-kuma container yok"; exit 1; }

repair_kuma_db_if_corrupt() {
  local db_dir="${REMOTE_DIR}/data/uptime-kuma"
  local db="${db_dir}/kuma.db"
  local stamp backup
  [[ -f "$db" ]] || return 0

  if docker exec uptime-kuma sqlite3 /app/data/kuma.db "PRAGMA integrity_check;" 2>/dev/null | grep -qx 'ok'; then
    return 0
  fi

  stamp="$(date +%Y%m%d-%H%M%S)"
  backup="${db_dir}/kuma.db.corrupt-${stamp}"
  log "Kuma DB bozuk — sqlite recover deneniyor"
  docker stop uptime-kuma >/dev/null 2>&1 || true
  cp -a "$db" "$backup"

  docker run --rm -u 0 -v "${db_dir}:/db" python:3.12-alpine sh -c '
    set -e
    apk add --no-cache sqlite >/dev/null
    sqlite3 /db/kuma.db ".recover" > /db/recovered.sql
    rm -f /db/kuma.db.new
    sqlite3 /db/kuma.db.new < /db/recovered.sql
    sqlite3 /db/kuma.db.new "PRAGMA integrity_check;" | grep -qx ok
    chown 1000:1000 /db/kuma.db.new
  '

  mv "$db" "${db}.pre-recover"
  mv "${db}.new" "$db"
  rm -f "${db_dir}/recovered.sql"
  docker start uptime-kuma >/dev/null
  wait_for_kuma_http
  log "Kuma DB recover tamamlandi: ${backup}"
}

wait_for_kuma_http() {
  local _
  for _ in $(seq 1 40); do
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
repair_kuma_db_if_corrupt
ensure_kuma_database
ensure_kuma_admin

# Kuma compose network gateway (host-network servisler icin); sabit 172.18 varsayma.
if [[ -n "${DOCKER_GATEWAY:-}" ]]; then
  DOCKER_GW="$DOCKER_GATEWAY"
else
  DOCKER_GW="$(docker inspect uptime-kuma --format '{{range $k,$v := .NetworkSettings.Networks}}{{$v.Gateway}}{{end}}' 2>/dev/null || true)"
fi
DOCKER_GW="${DOCKER_GW:-172.18.0.1}"
export KUMA_URL KUMA_USER KUMA_PASS PI_IP DOCKER_GW LAN_DOMAIN
export TELEGRAM_BOT_TOKEN="${TELEGRAM_BOT_TOKEN:-}"
export TELEGRAM_CHAT_ID="${TELEGRAM_CHAT_ID:-}"
export UPTIME_KUMA_STATUS_SLUG="${UPTIME_KUMA_STATUS_SLUG:-pi-gateway}"
export ENABLE_N8N="${ENABLE_N8N:-true}"
export ENABLE_NETALERTX="${ENABLE_NETALERTX:-true}"
export NETALERTX_PORT="${NETALERTX_PORT:-20211}"
export UPTIME_KUMA_SLOW_TIMEOUT="${UPTIME_KUMA_SLOW_TIMEOUT:-90}"
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
  -e ENABLE_N8N -e N8N_KUMA_WEBHOOK_URL -e ENABLE_NETALERTX -e NETALERTX_PORT -e UPTIME_KUMA_SLOW_TIMEOUT \
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
netalertx_port = os.environ.get("NETALERTX_PORT", "20211")
slow_timeout = int(os.environ.get("UPTIME_KUMA_SLOW_TIMEOUT", "90"))

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
    # *.home LAN IP hairpin Docker icinden timeout olur; Caddy hostname + Host header.
    (f"logs.{lan}", MonitorType.HTTP, {
        "url": "https://caddy:443",
        "headers": json.dumps({"Host": f"logs.{lan}"}),
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

if os.environ.get("ENABLE_NETALERTX", "true") == "true":
    monitors.append((f"devices.{lan}", MonitorType.HTTP, {
        "url": "https://caddy:443",
        "headers": json.dumps({"Host": f"devices.{lan}"}),
        "accepted_statuscodes": ok,
        "ignoreTls": True,
        "maxredirects": 0,
    }))
    # host-network NetAlertX: Kuma konteynerinden 127.0.0.1 degil docker gateway.
    monitors.append(("NetAlertX", MonitorType.HTTP, {
        "url": f"http://{gw}:{netalertx_port}",
        "accepted_statuscodes": ok,
    }))

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
slow_monitors = {f"devices.{lan}", f"logs.{lan}", "NetAlertX"}
updated = added = 0
for name, mtype, kwargs in monitors:
    base = {"type": mtype, "name": name, "interval": 60, "maxretries": 2, "conditions": [], **kwargs}
    if name in slow_monitors:
        base["timeout"] = slow_timeout
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
