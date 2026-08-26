#!/usr/bin/env bash
# LAN cihazlari vs AdGuard query log — DNS bypass / kapsam auditi
set -euo pipefail
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REMOTE_DIR="${REMOTE_DIR:-/home/${USER}/pi-gateway}"
_PG_ENV_LIB="${SCRIPT_DIR}/../lib/env-file.sh"
PG_SCRIPT_NAME="$(basename "$0")"
# shellcheck source=../lib/env-file.sh
source "${_PG_ENV_LIB:?}"
read_remote_dotenv || { echo "[${PG_SCRIPT_NAME:-script}] HATA: .env dotenv parser hatasi" >&2; exit 1; }
# shellcheck source=../lib/adguard-api.sh
source "$SCRIPT_DIR/../lib/adguard-api.sh"
PI_IP="${PI_STATIC_IP:-}"
if [[ "${LAN_SUBNET_CIDR:-}" =~ ^([0-9]+\.[0-9]+\.[0-9]+)\.[0-9]+/[0-9]+$ ]]; then
  LAN_NET_PREFIX="${BASH_REMATCH[1]}."
elif [[ -n "$PI_IP" ]]; then
  LAN_NET_PREFIX="${PI_IP%.*}."
else
  LAN_NET_PREFIX="192.168.1."
fi
GATEWAY_IP="${LAN_GATEWAY:-${LAN_NET_PREFIX}1}"
ADGUARD_WEB_PORT="${ADGUARD_WEB_PORT:-8080}"
QUERY_LIMIT="${ADGUARD_AUDIT_QUERY_LIMIT:-2000}"
MIN_QUERIES="${ADGUARD_AUDIT_MIN_QUERIES:-3}"
MIN_COVERAGE="${ADGUARD_MIN_COVERAGE_PERCENT:-50}"
BYPASS_CHECK="${ADGUARD_BYPASS_CHECK:-strict}"
AGH_ADMIN_USER="${AGH_ADMIN_USER:-admin}"
AGH_ADMIN_PASSWORD="${AGH_ADMIN_PASSWORD:-}"
fail=0
note_fail() { echo "[FAIL] $*"; fail=1; }
note_ok() { echo "[OK] $*"; }
note_warn() { echo "[WARN] $*"; }

echo "=== DNS kapsam auditi ==="
echo "Pi=${PI_IP} gateway=${GATEWAY_IP} (ARP + son ${QUERY_LIMIT} sorgu)"

[[ -n "$PI_IP" && -n "$AGH_ADMIN_PASSWORD" ]] || {
  note_fail "PI_STATIC_IP veya AGH_ADMIN_PASSWORD eksik"
  exit 1
}

COOKIE="$(mktemp)"
trap 'rm -f "$COOKIE"' EXIT
agh_login "http://127.0.0.1:${ADGUARD_WEB_PORT}" "$COOKIE" "$AGH_ADMIN_USER" "$AGH_ADMIN_PASSWORD" \
  || { note_fail "AdGuard API login"; exit 1; }

export COOKIE PI_IP GATEWAY_IP LAN_NET_PREFIX QUERY_LIMIT MIN_QUERIES MIN_COVERAGE BYPASS_CHECK ADGUARD_WEB_PORT REMOTE_DIR
python3 - <<'PY'
import json, os, subprocess, sys
from collections import Counter

pi_ip = os.environ["PI_IP"]
gateway = os.environ["GATEWAY_IP"]
lan_prefix = os.environ["LAN_NET_PREFIX"]
query_limit = int(os.environ["QUERY_LIMIT"])
min_queries = int(os.environ["MIN_QUERIES"])
min_cov = int(os.environ["MIN_COVERAGE"])
bypass_check = os.environ.get("BYPASS_CHECK", "strict")
port = os.environ["ADGUARD_WEB_PORT"]
cookie_file = os.environ["COOKIE"]

def curl_api(path):
    return subprocess.check_output(
        ["curl", "-fsS", "-b", cookie_file, f"http://127.0.0.1:{port}{path}"],
        text=True,
    )

# LAN cihazlari (ARP) — gateway haric; REACHABLE/DELAY = aktif, STALE = idle
def parse_neigh():
    online, idle = set(), set()
    for line in subprocess.check_output(["ip", "neigh", "show"], text=True).splitlines():
        parts = line.split()
        if len(parts) < 5:
            continue
        ip, state = parts[0], parts[-1]
        if not ip.startswith(lan_prefix) or ip in (pi_ip, gateway):
            continue
        if state in ("REACHABLE", "DELAY"):
            online.add(ip)
        elif state in ("STALE", "PROBE"):
            idle.add(ip)
    return online, idle

online_ips, idle_ips = parse_neigh()
for ip in sorted(online_ips | idle_ips):
    subprocess.run(
        ["ping", "-c1", "-W1", ip],
        stdout=subprocess.DEVNULL,
        stderr=subprocess.DEVNULL,
    )
online_ips, idle_ips = parse_neigh()
lan_ips = online_ips | idle_ips

def probe_ok(ip):
    return subprocess.run(
        ["ping", "-c1", "-W1", ip],
        stdout=subprocess.DEVNULL,
        stderr=subprocess.DEVNULL,
    ).returncode == 0

def mac_for(ip):
    try:
        out = subprocess.check_output(["ip", "neigh", "show", ip], text=True, stderr=subprocess.DEVNULL).strip()
    except subprocess.CalledProcessError:
        return "?"
    parts = out.split()
    if "lladdr" in parts:
        return parts[parts.index("lladdr") + 1]
    return "?"

def load_names():
    by_ip, by_mac = {}, {}
    try:
        clients = json.loads(curl_api("/control/clients"))
        for bucket in ("clients", "auto_clients"):
            for c in clients.get(bucket) or []:
                n = (c.get("name") or "").strip()
                if not n:
                    continue
                for ident in c.get("ids") or []:
                    ident = str(ident).strip()
                    if ident.count(".") == 3:
                        by_ip.setdefault(ident, n)
                    elif ":" in ident:
                        by_mac.setdefault(ident.lower(), n)
                ip = str(c.get("ip") or "").strip()
                if ip.count(".") == 3:
                    by_ip.setdefault(ip, n)
    except (subprocess.CalledProcessError, json.JSONDecodeError, TypeError):
        pass
    db = os.path.join(os.environ.get("REMOTE_DIR", ""), "data/netalertx/db/app.db")
    if os.path.isfile(db):
        try:
            import sqlite3
            con = sqlite3.connect(f"file:{db}?mode=ro", uri=True)
            for ip, name, mac in con.execute("SELECT devLastIP, devName, devMac FROM Devices"):
                n = (name or "").strip()
                if ip and n:
                    by_ip[ip] = n
                if mac and n:
                    by_mac[mac.lower()] = n
            con.close()
        except Exception:
            pass
    return by_ip, by_mac

by_ip_name, by_mac_name = load_names()

def host_label(ip):
    n = by_ip_name.get(ip) or by_mac_name.get(mac_for(ip).lower(), "")
    return f" {n}" if n else ""

ql = json.loads(curl_api(f"/control/querylog?older_than=&limit={query_limit}"))
clients = Counter()
blocked = Counter()
for row in ql.get("data", []):
    ip = row.get("client", "")
    if not ip.startswith(lan_prefix) or ip == pi_ip:
        continue
    clients[ip] += 1
    reason = str(row.get("reason", ""))
    if reason and reason not in ("NotFilteredNotFound", "NotFilteredWhiteList"):
        blocked[ip] += 1

verified_active = {ip for ip in online_ips if probe_ok(ip)}
# REACHABLE/DELAY = online say; ICMP kapali olsa bile 0 sorgu = BYPASS (false OK engelle)
strict_ips = set(online_ips) | {ip for ip in lan_ips if clients.get(ip, 0) > 0}

active = {ip for ip in lan_ips if clients.get(ip, 0) >= min_queries}
strict_active = {ip for ip in strict_ips if clients.get(ip, 0) >= min_queries}
missing_strict = sorted(ip for ip in strict_ips if clients.get(ip, 0) == 0)
missing_idle = sorted(ip for ip in idle_ips if clients.get(ip, 0) == 0 and ip not in strict_ips)
low = sorted(ip for ip in lan_ips if 0 < clients.get(ip, 0) < min_queries)

total = len(lan_ips)
using = len(active)
strict_total = len(strict_ips)
cov = round(100 * using / max(1, total))
strict_cov = round(100 * len(strict_active) / max(1, strict_total)) if strict_total else 100

print(f"LAN cihaz (ARP, gateway haric): {total} (REACHABLE/DELAY: {len(online_ips)}, ping-ok: {len(verified_active)}, idle STALE: {len(idle_ips)})")
if lan_ips:
    print("  " + ", ".join(f"{ip}{host_label(ip)}" for ip in sorted(lan_ips)))
print(f"Pi DNS aktif (>={min_queries} sorgu): {using}/{total} (%{cov}) | aktif cihaz: {len(strict_active)}/{strict_total} (%{strict_cov})")
for ip in sorted(active):
    print(f"  [OK] {ip}{host_label(ip)}: {clients[ip]} sorgu, {blocked.get(ip, 0)} engel")
for ip in low:
    tag = "IDLE" if ip in idle_ips else "WARN"
    print(f"  [{tag}] {ip}{host_label(ip)}: {clients[ip]} sorgu (cok az — DHCP yenile veya Private DNS kapat)")
for ip in missing_strict:
    icmp = "ping-ok" if ip in verified_active else "ICMP-kapali/filtre"
    print(f"  [BYPASS] {ip}{host_label(ip)} ({mac_for(ip)}, {icmp}): ARP aktif, Pi DNS yok")
for ip in missing_idle:
    print(f"  [IDLE] {ip}{host_label(ip)} ({mac_for(ip)}): STALE ARP, query logda yok")

print("")
print("=== Olası nedenler (modem DNS tek basina yetmez) ===")
print("  1. Modemde WAN DNS degil LAN/DHCP DNS ayarlanmali")
print("  2. Ikincil DNS 8.8.8.8/1.1.1.1 olmasin (ZTE H3600P panel DNS2 yok sayilir, OFFER yine .1 basar)")
print("  3. Cihazlar eski DHCP lease — Wi-Fi kapat/ac veya reboot")
print("  4. Android Ozel DNS / iOS Private Relay kapali olmali")
print("  5. IPv6 DNS (modem RDNSS) Pi yerine baska sunucu verebilir")
print("  6. TV/konsol sabit DNS kullanabilir — elle Pi IP gir")
print("")
print("=== Cozum secenekleri ===")
print("  A) Modem: DHCP DNS1={} DNS2=BOS + tum cihaz reboot".format(pi_ip))
print("  B) NETWORK_MODE=adguard-dhcp — ZTE H3600P'te DENEME (relay DISCOVER yutuyor); baska modem + UFW UDP/67")
print("  C) Ethernet+WiFi: kablolu NIC public DNS WAN :53 drop keser — Mac: make mac-dns")
print("  D) IPv6: radvd 3–4s + modem LL lifetime 0; modem RA 900s last-RA. Anlamazsa make mac-dns")

if bypass_check == "off":
    print("COVERAGE_OK")
    sys.exit(0)
if bypass_check == "warn":
    if missing_strict or (strict_total and strict_cov < min_cov):
        print(f"[WARN] aktif kapsam %{strict_cov} — bypass: {', '.join(missing_strict) or 'yok'}")
    print("COVERAGE_OK")
    sys.exit(0)
if strict_total and strict_cov < min_cov:
    print(f"COVERAGE_FAIL:{strict_cov}")
    sys.exit(10)
if missing_strict:
    print("MISSING_DEVICES:" + ",".join(missing_strict))
    sys.exit(11)
print("COVERAGE_OK")
PY
rc=$?
case "$rc" in
  0)
    note_ok "DNS kapsami yeterli"
    ;;
  10|11)
    note_fail "DNS kapsami dusuk — bazi cihazlar Pi DNS kullanmiyor"
    fail=1
    ;;
  *)
    note_fail "audit script hatasi (exit $rc)"
    fail=1
    ;;
esac
exit "$fail"
