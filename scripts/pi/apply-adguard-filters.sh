#!/usr/bin/env bash
# AdGuard filtre seti — idempotent (yalnizca fark uygular)
set -euo pipefail
REMOTE_DIR="${REMOTE_DIR:-/home/${USER}/pi-gateway}"
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
_PG_ENV_LIB="${SCRIPT_DIR:-$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)}/../lib/env-file.sh"
PG_SCRIPT_NAME="$(basename "$0")"
# shellcheck source=../lib/env-file.sh
source "${_PG_ENV_LIB:?}"
read_remote_dotenv || { echo "[${PG_SCRIPT_NAME:-script}] HATA: .env dotenv parser hatasi" >&2; exit 1; }
source "$SCRIPT_DIR/../lib/adguard-api.sh"
AGH_ADMIN_USER="${AGH_ADMIN_USER:-admin}"
AGH_ADMIN_PASSWORD="${AGH_ADMIN_PASSWORD:-}"
ADGUARD_WEB_PORT="${ADGUARD_WEB_PORT:-8080}"
HAGEZI_TIF_FILTER_URL="${HAGEZI_TIF_FILTER_URL:-https://cdn.jsdelivr.net/gh/hagezi/dns-blocklists@latest/adblock/tif.medium.txt}"
BASE="http://127.0.0.1:${ADGUARD_WEB_PORT}"
[[ -n "$AGH_ADMIN_PASSWORD" ]] || { echo "[adguard-filters] AGH_ADMIN_PASSWORD bos"; exit 1; }
COOKIE="$(mktemp)"
trap 'rm -f "$COOKIE"' EXIT
log() { echo "[adguard-filters] $*"; }
login() {
  agh_login "$BASE" "$COOKIE" "$AGH_ADMIN_USER" "$AGH_ADMIN_PASSWORD"
}
login || { log "AdGuard login basarisiz"; exit 1; }
export BASE COOKIE HAGEZI_TIF_FILTER_URL
python3 - <<'PY'
import json, os, subprocess, sys
base = os.environ["BASE"]
cookie = os.environ["COOKIE"]
tif_url = os.environ["HAGEZI_TIF_FILTER_URL"]
desired = [
    ("HaGeZi Pro++", "https://adguardteam.github.io/HostlistsRegistry/assets/filter_51.txt"),
    ("HaGeZi TIF Medium", tif_url),
    ("AdGuard DNS Popup Hosts", "https://adguardteam.github.io/HostlistsRegistry/assets/filter_59.txt"),
    ("HaGeZi Apple Tracker", "https://adguardteam.github.io/HostlistsRegistry/assets/filter_67.txt"),
    ("HaGeZi Windows/Office Tracker", "https://adguardteam.github.io/HostlistsRegistry/assets/filter_63.txt"),
    ("HaGeZi Samsung Tracker", "https://adguardteam.github.io/HostlistsRegistry/assets/filter_61.txt"),
]
desired_urls = {url for _, url in desired}
rules = [
    "||pagead.l.doubleclick.net^$important",
    "||pagead2.googlesyndication.com^$important",
    "||googleads.g.doubleclick.net^$important",
    "||securepubads.g.doubleclick.net^$important",
    "||adservice.google.com^$important",
    "||adservice.google.com.tr^$important",
    "||ad.doubleclick.net^$important",
    "||static.doubleclick.net^$important",
    "||googletagmanager.com^$important",
    "||www.googletagmanager.com^$important",
    "||googletagservices.com^$important",
    "||ads.reddit.com^$important",
    "||ads.twitter.com^$important",
    "||ads-api.twitter.com^$important",
    "||an.facebook.com^$important",
    "||ads.linkedin.com^$important",
    "||amazon-adsystem.com^$important",
    "||aax.amazon-adsystem.com^$important",
    "||adnxs.com^$important",
    "||adsrvr.org^$important",
    "||pubmatic.com^$important",
    "||rubiconproject.com^$important",
    "||criteo.com^$important",
    "||criteo.net^$important",
    "||taboola.com^$important",
    "||outbrain.com^$important",
    "||moatads.com^$important",
    "||scorecardresearch.com^$important",
    "||adform.net^$important",
    "||gemius.pl^$important",
    "||hit.gemius.pl^$important",
]
def api(path, method="GET", payload=None):
    cmd = ["curl", "-fsS", "-b", cookie, "-X", method, f"{base}{path}"]
    if payload is not None:
        cmd += ["-H", "Content-Type: application/json", "-d", json.dumps(payload)]
    out = subprocess.check_output(cmd, text=True)
    return json.loads(out) if out.strip() else {}
status = api("/control/filtering/status")
current = {f.get("url"): f for f in status.get("filters", []) if f.get("url")}
removed = added = 0
for url in sorted(set(current) - desired_urls):
    api("/control/filtering/remove_url", "POST", {"url": url})
    print(f"[adguard-filters] kaldirildi: {current[url].get('name', url)}")
    removed += 1
for name, url in desired:
    if url in current:
        print(f"[adguard-filters] mevcut: {name}")
        continue
    api("/control/filtering/add_url", "POST", {"name": name, "url": url, "whitelist": False})
    print(f"[adguard-filters] eklendi: {name}")
    added += 1
api("/control/filtering/set_rules", "POST", {"rules": rules, "enabled": True})
print(f"[adguard-filters] user rules: {len(rules)}")
if added or removed:
    api("/control/filtering/refresh", "POST", {"whitelist": False})
    print("[adguard-filters] filtreler yenilendi")
else:
    print("[adguard-filters] filtre seti degismedi")
PY
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
if [[ -x "$SCRIPT_DIR/apply-adguard-rewrites.sh" ]]; then
  bash "$SCRIPT_DIR/apply-adguard-rewrites.sh"
fi
log "Tamamlandi"
