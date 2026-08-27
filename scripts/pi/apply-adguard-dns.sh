#!/usr/bin/env bash
# AdGuard DNS ayarlari: UDP upstream, TTL, PTR, timeout, ratelimit, cache, querylog/stats retention
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
# Tailscale Override / LAN burst: 20 dusuk kalabilir (SERVFAIL). Dusurme.
RATELIMIT="${ADGUARD_RATELIMIT:-50}"
CACHE_SIZE="${ADGUARD_CACHE_SIZE:-16777216}"
# AGH API: gun (integer). YAML template 168h ile uyumlu.
QUERYLOG_DAYS="${ADGUARD_QUERYLOG_INTERVAL_DAYS:-7}"
STATS_DAYS="${ADGUARD_STATS_INTERVAL_DAYS:-7}"
export BLOCKED_TTL UPSTREAM_TIMEOUT RATELIMIT CACHE_SIZE QUERYLOG_DAYS STATS_DAYS BASE COOKIE UNBOUND_PORT
python3 - <<'PY'
import json, os, subprocess, sys

base = os.environ["BASE"]
cookie = os.environ["COOKIE"]
unbound_port = int(os.environ["UNBOUND_PORT"])
blocked_ttl = int(os.environ["BLOCKED_TTL"])
upstream_timeout = int(os.environ["UPSTREAM_TIMEOUT"])
ratelimit = int(os.environ["RATELIMIT"])
cache_size = int(os.environ["CACHE_SIZE"])
querylog_days = int(os.environ["QUERYLOG_DAYS"])
stats_days = int(os.environ["STATS_DAYS"])

if ratelimit < 1 or cache_size < 1048576:
    print("[adguard-dns] HATA: ratelimit/cache_size gecersiz", file=sys.stderr)
    sys.exit(1)
if querylog_days < 1 or querylog_days > 90 or stats_days < 1 or stats_days > 90:
    print("[adguard-dns] HATA: querylog/stats interval 1..90 gun", file=sys.stderr)
    sys.exit(1)

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
desired["ratelimit"] = ratelimit
desired["cache_size"] = cache_size


def dns_field_changed(key):
    if key == "default_local_ptr_upstreams":
        # API bos liste yerine router varsayilanini dondurur; PTR kapaliysa yoksay
        if desired.get("use_private_ptr_resolvers") is False:
            return False
    return current.get(key) != desired.get(key)


changed = [k for k in desired if dns_field_changed(k)]
if not changed:
    print("[adguard-dns] dns ayarlari zaten guncel")
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

# Querylog / stats retention (gun)
ql = json.loads(
    subprocess.check_output(
        ["curl", "-fsS", "-b", cookie, f"{base}/control/querylog_info"],
        text=True,
    )
)
st = json.loads(
    subprocess.check_output(
        ["curl", "-fsS", "-b", cookie, f"{base}/control/stats_info"],
        text=True,
    )
)
ql_desired = {
    "enabled": True,
    "interval": querylog_days,
    "anonymize_client_ip": bool(ql.get("anonymize_client_ip", False)),
}
st_desired = {"interval": stats_days}
if ql.get("enabled") is not True or int(ql.get("interval") or 0) != querylog_days:
    subprocess.run(
        [
            "curl", "-fsS", "-b", cookie,
            "-X", "POST", f"{base}/control/querylog_config",
            "-H", "Content-Type: application/json",
            "-d", json.dumps(ql_desired),
        ],
        check=True,
    )
    print(f"[adguard-dns] querylog interval={querylog_days}d")
else:
    print("[adguard-dns] querylog zaten guncel")
if int(st.get("interval") or 0) != stats_days:
    subprocess.run(
        [
            "curl", "-fsS", "-b", cookie,
            "-X", "POST", f"{base}/control/stats_config",
            "-H", "Content-Type: application/json",
            "-d", json.dumps(st_desired),
        ],
        check=True,
    )
    print(f"[adguard-dns] stats interval={stats_days}d")
else:
    print("[adguard-dns] stats zaten guncel")

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
if int(final.get("ratelimit") or 0) != ratelimit:
    print("[adguard-dns] HATA: ratelimit uyusmuyor", final.get("ratelimit"), file=sys.stderr)
    sys.exit(1)
if int(final.get("cache_size") or 0) != cache_size:
    print("[adguard-dns] HATA: cache_size uyusmuyor", final.get("cache_size"), file=sys.stderr)
    sys.exit(1)
ql_final = json.loads(
    subprocess.check_output(
        ["curl", "-fsS", "-b", cookie, f"{base}/control/querylog_info"],
        text=True,
    )
)
st_final = json.loads(
    subprocess.check_output(
        ["curl", "-fsS", "-b", cookie, f"{base}/control/stats_info"],
        text=True,
    )
)
if int(ql_final.get("interval") or 0) != querylog_days:
    print("[adguard-dns] HATA: querylog interval uyusmuyor", ql_final, file=sys.stderr)
    sys.exit(1)
if int(st_final.get("interval") or 0) != stats_days:
    print("[adguard-dns] HATA: stats interval uyusmuyor", st_final, file=sys.stderr)
    sys.exit(1)
print("[adguard-dns] dogrulama OK")
PY
log "Tamamlandi"
