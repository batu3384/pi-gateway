#!/usr/bin/env bash
# AdGuard DNS ayarlari: UDP upstream, TTL, PTR, timeout
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
UNBOUND_PORT="${UNBOUND_PORT:-5335}"
BASE="http://127.0.0.1:${ADGUARD_WEB_PORT}"
[[ -n "$AGH_ADMIN_PASSWORD" ]] || { echo "[adguard-dns] AGH_ADMIN_PASSWORD bos"; exit 1; }
COOKIE="$(mktemp)"
trap 'rm -f "$COOKIE"' EXIT
log() { echo "[adguard-dns] $*"; }
agh_login "$BASE" "$COOKIE" "$AGH_ADMIN_USER" "$AGH_ADMIN_PASSWORD" || {
  log "AdGuard login basarisiz"
  exit 1
}
curl -fsS -b "$COOKIE" "${BASE}/control/dns_info" > /tmp/agh-dns-info.json
BLOCKED_TTL="${ADGUARD_BLOCKED_TTL:-60}"
UPSTREAM_TIMEOUT="${ADGUARD_UPSTREAM_TIMEOUT:-5}"
python3 - <<PY
import json, subprocess, sys
base = "${BASE}"
cookie = "${COOKIE}"
unbound_port = int("${UNBOUND_PORT}")
blocked_ttl = int("${BLOCKED_TTL}")
upstream_timeout = int("${UPSTREAM_TIMEOUT}")
with open("/tmp/agh-dns-info.json") as f:
    current = json.load(f)
desired = dict(current)
desired["upstream_dns"] = [
    f"udp://127.0.0.1:{unbound_port}",
    f"tcp://127.0.0.1:{unbound_port}",
]
desired["bootstrap_dns"] = [f"127.0.0.1:{unbound_port}"]
desired["fallback_dns"] = []
desired["blocked_response_ttl"] = blocked_ttl
desired["upstream_timeout"] = upstream_timeout
desired["use_private_ptr_resolvers"] = False
desired["local_ptr_upstreams"] = []
desired["default_local_ptr_upstreams"] = []
def dns_field_changed(key):
    if key == "default_local_ptr_upstreams":
        # API bos liste yerine router varsayilanini dondurur; PTR kapaliysa yoksay
        if desired.get("use_private_ptr_resolvers") is False:
            return False
    return current.get(key) != desired.get(key)
changed = [k for k in desired if dns_field_changed(k)]
if not changed:
    print("[adguard-dns] ayarlar zaten guncel")
else:
    body = json.dumps(desired)
    subprocess.run(
        [
            "curl", "-fsS", "-b", cookie,
            "-X", "POST", f"{base}/control/dns_config",
            "-H", "Content-Type: application/json",
            "-d", body,
        ],
        check=True,
    )
    for k in changed:
        print(f"[adguard-dns] guncellendi: {k}={desired[k]!r}")
# Dogrulama: kritik alanlar
verify = subprocess.check_output(
    ["curl", "-fsS", "-b", cookie, f"{base}/control/dns_info"],
    text=True,
)
final = json.loads(verify)
upstream = final.get("upstream_dns") or []
if not any(u.startswith("udp://127.0.0.1:") for u in upstream):
    print("[adguard-dns] HATA: UDP upstream eksik", upstream, file=sys.stderr)
    sys.exit(1)
if final.get("use_private_ptr_resolvers") is not False:
    print("[adguard-dns] HATA: use_private_ptr_resolvers hala acik", file=sys.stderr)
    sys.exit(1)
if final.get("blocked_response_ttl") != blocked_ttl:
    print("[adguard-dns] HATA: blocked_response_ttl uyusmuyor", file=sys.stderr)
    sys.exit(1)
print("[adguard-dns] dogrulama OK")
PY
log "Tamamlandi"
