#!/usr/bin/env bash
# AdGuard DNS rewrite'lari tek API listesi uzerinden idempotent uygular
set -euo pipefail
REMOTE_DIR="${REMOTE_DIR:-/home/${USER}/pi-gateway}"
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
_PG_ENV_LIB="${SCRIPT_DIR:-$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)}/../lib/env-file.sh"
PG_SCRIPT_NAME="$(basename "$0")"
# shellcheck source=../lib/env-file.sh
source "${_PG_ENV_LIB:?}"
read_remote_dotenv || { echo "[${PG_SCRIPT_NAME:-script}] HATA: .env dotenv parser hatasi" >&2; exit 1; }
source "$SCRIPT_DIR/../lib/adguard-api.sh"
PI_STATIC_IP="${PI_STATIC_IP:-}"
LAN_DOMAIN="${LAN_DOMAIN:-home}"
ENABLE_N8N="${ENABLE_N8N:-false}"
AGH_ADMIN_USER="${AGH_ADMIN_USER:-admin}"
AGH_ADMIN_PASSWORD="${AGH_ADMIN_PASSWORD:-}"
ADGUARD_WEB_PORT="${ADGUARD_WEB_PORT:-8080}"
BASE="http://127.0.0.1:${ADGUARD_WEB_PORT}"
[[ -n "$PI_STATIC_IP" ]] || { echo "[adguard-rewrites] PI_STATIC_IP bos"; exit 1; }
[[ -n "$AGH_ADMIN_PASSWORD" ]] || { echo "[adguard-rewrites] AGH_ADMIN_PASSWORD bos"; exit 1; }
COOKIE="$(mktemp)"
trap 'rm -f "$COOKIE"' EXIT
log() { echo "[adguard-rewrites] $*"; }
agh_login "$BASE" "$COOKIE" "$AGH_ADMIN_USER" "$AGH_ADMIN_PASSWORD" || {
  log "AdGuard login basarisiz"
  exit 1
}

export BASE COOKIE PI_STATIC_IP LAN_DOMAIN ENABLE_N8N
python3 - <<'PY'
import json
import os
import subprocess
import sys

base = os.environ["BASE"]
cookie = os.environ["COOKIE"]
pi_ip = os.environ["PI_STATIC_IP"]
lan_dom = os.environ["LAN_DOMAIN"]
enable_n8n = os.environ.get("ENABLE_N8N", "false").lower() == "true"


def api_get(path: str):
    out = subprocess.check_output(["curl", "-fsS", "-b", cookie, f"{base}{path}"], text=True)
    return json.loads(out)


def api_post(path: str, payload: dict) -> None:
    subprocess.run(
        [
            "curl", "-fsS", "-b", cookie, "-X", "POST", f"{base}{path}",
            "-H", "Content-Type: application/json",
            "--data-binary", json.dumps(payload),
        ],
        check=True,
        stdout=subprocess.DEVNULL,
    )


rows = api_get("/control/rewrite/list")
obsolete_subs = ["git", "sync"]
desired_subs = ["gateway", "dns", "status", "panel", "logs", "devices", "grafana"]
if enable_n8n:
    desired_subs.append("n8n")
else:
    obsolete_subs.append("n8n")

obsolete_domains = {f"{s}.{lan_dom}" for s in obsolete_subs}
desired_map = {f"{s}.{lan_dom}": pi_ip for s in desired_subs}

for row in rows:
    dom = row.get("domain", "")
    ans = row.get("answer", "")
    if dom in obsolete_domains or (dom in desired_map and ans != desired_map[dom]):
        api_post("/control/rewrite/delete", {"domain": dom, "answer": ans})
        print(f"[adguard-rewrites] silindi: {dom} -> {ans}")

existing = {(r.get("domain"), r.get("answer")) for r in api_get("/control/rewrite/list")}
for dom, ans in desired_map.items():
    if (dom, ans) in existing:
        print(f"[adguard-rewrites] mevcut: {dom} -> {ans}")
    else:
        api_post("/control/rewrite/add", {"domain": dom, "answer": ans})
        print(f"[adguard-rewrites] eklendi: {dom} -> {ans}")

final_rows = api_get("/control/rewrite/list")
if len(final_rows) < len(desired_map):
    print(f"[adguard-rewrites] HATA: beklenen en az {len(desired_map)} rewrite, bulunan {len(final_rows)}", file=sys.stderr)
    sys.exit(1)
print(f"[adguard-rewrites] Tamamlandi ({len(desired_map)} rewrite dogrulandi)")
PY
