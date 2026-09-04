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
BYPASS_CHECK="${ADGUARD_COVERAGE_AUDIT_MODE:-${ADGUARD_BYPASS_CHECK:-strict}}"
AGH_ADMIN_USER="${AGH_ADMIN_USER:-admin}"
AGH_ADMIN_PASSWORD="${AGH_ADMIN_PASSWORD:-}"
MODEM_INVENTORY_PATH="${MODEM_INVENTORY_PATH:-${REMOTE_DIR}/data/modem-inventory.json}"
MODEM_INVENTORY_STALE_SEC="${MODEM_INVENTORY_STALE_SEC:-900}"
MODEM_INVENTORY_REQUIRED="${MODEM_INVENTORY_REQUIRED:-false}"
NETALERTX_RECENCY_SEC="${NETALERTX_RECENCY_SEC:-900}"
QUERY_RECENCY_SEC="${ADGUARD_AUDIT_QUERY_RECENCY_SEC:-${NETALERTX_RECENCY_SEC}}"
[[ "$MODEM_INVENTORY_STALE_SEC" =~ ^[0-9]+$ ]] || {
  echo "[${PG_SCRIPT_NAME}] HATA: MODEM_INVENTORY_STALE_SEC sayi olmali" >&2
  exit 1
}
[[ "$NETALERTX_RECENCY_SEC" =~ ^[0-9]+$ ]] || {
  echo "[${PG_SCRIPT_NAME}] HATA: NETALERTX_RECENCY_SEC sayi olmali" >&2
  exit 1
}
[[ "$QUERY_RECENCY_SEC" =~ ^[0-9]+$ ]] || {
  echo "[${PG_SCRIPT_NAME}] HATA: ADGUARD_AUDIT_QUERY_RECENCY_SEC sayi olmali" >&2
  exit 1
}
fail=0
note_fail() { echo "[FAIL] $*"; fail=1; }
note_ok() { echo "[OK] $*"; }
note_warn() { echo "[WARN] $*"; }
coverage_state_status() {
  python3 - "${ADGUARD_DNS_COVERAGE_STATE_PATH:-/var/lib/pi-gateway/dns-coverage-state.json}" <<'PY' || printf 'unknown'
import json
import sys

try:
    with open(sys.argv[1], encoding="utf-8") as fh:
        status = json.load(fh).get("status", "unknown")
except (OSError, TypeError, ValueError, json.JSONDecodeError):
    status = "unknown"
print(status)
PY
}

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

export COOKIE PI_IP GATEWAY_IP LAN_NET_PREFIX QUERY_LIMIT MIN_QUERIES MIN_COVERAGE BYPASS_CHECK ADGUARD_WEB_PORT REMOTE_DIR MODEM_INVENTORY_PATH MODEM_INVENTORY_STALE_SEC MODEM_INVENTORY_REQUIRED MODEM_INVENTORY_ENABLED NETALERTX_RECENCY_SEC QUERY_RECENCY_SEC
set +e
python3 - <<'PY'
import ipaddress
import json, os, subprocess, sys, tempfile
from collections import Counter, defaultdict
from datetime import datetime, timezone

sys.path.insert(0, os.path.join(os.environ["REMOTE_DIR"], "scripts", "lib"))
from modem_inventory import load_modem_inventory, modem_device

pi_ip = os.environ["PI_IP"]
gateway = os.environ["GATEWAY_IP"]
lan_prefix = os.environ["LAN_NET_PREFIX"]
query_limit = int(os.environ["QUERY_LIMIT"])
min_queries = int(os.environ["MIN_QUERIES"])
min_cov = int(os.environ["MIN_COVERAGE"])
bypass_check = os.environ.get("BYPASS_CHECK", "strict")
port = os.environ["ADGUARD_WEB_PORT"]
cookie_file = os.environ["COOKIE"]
modem_path = os.environ["MODEM_INVENTORY_PATH"]
modem_stale_sec = int(os.environ["MODEM_INVENTORY_STALE_SEC"])
modem_required = (
    os.environ.get("MODEM_INVENTORY_REQUIRED", "false") == "true"
    or os.environ.get("MODEM_INVENTORY_ENABLED", "false") == "true"
)
netalert_recency_sec = int(os.environ["NETALERTX_RECENCY_SEC"])
query_recency_sec = int(os.environ["QUERY_RECENCY_SEC"])

def curl_api(path):
    return subprocess.check_output(
        ["curl", "-fsS", "-b", cookie_file, f"http://127.0.0.1:{port}{path}"],
        text=True,
    )

def parse_neigh():
    online, idle, macs = set(), set(), {}
    try:
        lines = subprocess.check_output(["ip", "neigh", "show"], text=True).splitlines()
    except (OSError, subprocess.CalledProcessError):
        return online, idle, macs
    for line in lines:
        parts = line.split()
        if len(parts) < 2:
            continue
        ip, state = parts[0], parts[-1]
        if not ip.startswith(lan_prefix) or ip in (pi_ip, gateway):
            continue
        if "lladdr" in parts:
            macs[ip] = parts[parts.index("lladdr") + 1].lower()
        if state in ("REACHABLE", "DELAY"):
            online.add(ip)
        elif state in ("STALE", "PROBE"):
            idle.add(ip)
    return online, idle, macs

online_ips, idle_ips, neigh_macs = parse_neigh()

modem = load_modem_inventory(modem_path, modem_stale_sec)
modem["ips"] = {
    ip for ip in modem.get("ips", set())
    if ip.startswith(lan_prefix) and ip not in (pi_ip, gateway)
}

def mac_for(ip):
    return neigh_macs.get(ip) or modem["mac_by_ip"].get(ip, "?")

def load_names():
    agh_ip, agh_mac = {}, {}
    try:
        clients_data = json.loads(curl_api("/control/clients"))
        for bucket in ("clients", "auto_clients"):
            for client in clients_data.get(bucket) or []:
                name = (client.get("name") or "").strip()
                if not name:
                    continue
                for ident in client.get("ids") or []:
                    ident = str(ident).strip()
                    if ident.count(".") == 3:
                        agh_ip.setdefault(ident, name)
                    elif ":" in ident:
                        agh_mac.setdefault(ident.lower(), name)
                ip = str(client.get("ip") or "").strip()
                if ip.count(".") == 3:
                    agh_ip.setdefault(ip, name)
    except (subprocess.CalledProcessError, json.JSONDecodeError, TypeError):
        pass
    db_ip, db_mac, netalert_seen = {}, {}, {}
    db_readable = False
    db = os.path.join(os.environ.get("REMOTE_DIR", ""), "data/netalertx/db/app.db")
    if os.path.isfile(db):
        try:
            import sqlite3
            con = sqlite3.connect(f"file:{db}?mode=ro", uri=True)
            db_cols = {row[1] for row in con.execute("PRAGMA table_info(Devices)")}
            last_seen_column = "devLastConnection" if "devLastConnection" in db_cols else "NULL"
            for ip, name, mac, last_seen in con.execute(
                f"SELECT devLastIP, devName, devMac, {last_seen_column} FROM Devices"
            ):
                name = (name or "").strip()
                if ip and name:
                    db_ip[ip] = name
                if mac and name:
                    db_mac[mac.lower()] = name
                if ip and last_seen:
                    try:
                        seen_value = float(last_seen)
                        netalert_seen[ip] = seen_value / 1000 if seen_value > 100000000000 else seen_value
                    except (TypeError, ValueError):
                        pass
            con.close()
            db_readable = True
        except Exception:
            pass
    return agh_ip, agh_mac, db_ip, db_mac, netalert_seen, db_readable

agh_ip, agh_mac, db_ip, db_mac, netalert_seen, netalert_db_readable = load_names()

def host_label(ip):
    mac = mac_for(ip).lower()
    record = modem_device(modem, mac, ip)
    name = (
        record.get("name") or record.get("label")
        or db_mac.get(mac)
        or db_ip.get(ip)
        or agh_mac.get(mac)
        or agh_ip.get(ip)
        or ""
    )
    metadata = []
    if record.get("source"):
        metadata.append(f"source={record['source']}")
    if record.get("confidence"):
        metadata.append(f"confidence={record['confidence']}")
    if record.get("privacy_mac"):
        metadata.append("privacy_mac=true")
    if record.get("last_seen"):
        metadata.append(f"last_seen={record['last_seen']}")
    suffix = f" [{','.join(metadata)}]" if metadata else ""
    return f" {name}{suffix}" if name else suffix

def seen_label(ip):
    seen = netalert_seen.get(ip)
    if seen is None:
        return "last_seen=?"
    return f"last_seen={max(0, int(now_ts - seen))}s"

ql = json.loads(curl_api(f"/control/querylog?older_than=&limit={query_limit}"))
clients, blocked = Counter(), Counter()
protocols = defaultdict(Counter)
ipv6_query_clients = Counter()
now_ts = datetime.now(timezone.utc).timestamp()

def query_is_recent(row):
    raw_time = row.get("time") or row.get("timestamp")
    if not raw_time:
        return True
    try:
        query_ts = datetime.fromisoformat(
            str(raw_time).replace("Z", "+00:00")
        ).timestamp()
    except (TypeError, ValueError):
        return False
    age = now_ts - query_ts
    return 0 <= age <= query_recency_sec

for row in ql.get("data", []):
    if not query_is_recent(row):
        continue
    ip = str(row.get("client_ip") or row.get("client") or "")
    try:
        parsed_ip = ipaddress.ip_address(ip)
    except ValueError:
        parsed_ip = None
    if parsed_ip is not None and parsed_ip.version == 6:
        ipv6_query_clients[ip] += 1
        continue
    if not ip.startswith(lan_prefix) or ip in (pi_ip, gateway):
        continue
    clients[ip] += 1
    proto = str(
        row.get("client_proto")
        or row.get("protocol")
        or row.get("proto")
        or "api-unknown"
    )
    protocols[ip][proto] += 1
    reason = str(row.get("reason", ""))
    if reason and reason not in ("NotFilteredNotFound", "NotFilteredWhiteList"):
        blocked[ip] += 1

query_ips = set(clients)
observed_ips = online_ips | idle_ips
recent_netalert_ips = {
    ip for ip, seen in netalert_seen.items()
    if 0 <= now_ts - seen <= netalert_recency_sec
}
snapshot_ips = set(modem["ips"])
if modem["fresh"]:
    modem_ips = snapshot_ips
    active_ips = modem_ips & (online_ips | query_ips | recent_netalert_ips)
    unknown_ips = sorted((online_ips | query_ips) - modem_ips)
    stale_ips = sorted(
        ip for ip in (modem_ips | idle_ips)
        if ip not in active_ips and ip not in recent_netalert_ips
    )
else:
    modem_ips = set()
    active_ips = online_ips | query_ips | recent_netalert_ips
    unknown_ips = []
    stale_ips = sorted(
        ip for ip in (snapshot_ips | idle_ips)
        if clients.get(ip, 0) == 0 and ip not in recent_netalert_ips
    )

using_ips = {ip for ip in active_ips if clients.get(ip, 0) >= min_queries}
low = sorted(ip for ip in active_ips if 0 < clients.get(ip, 0) < min_queries)
possible_bypass = sorted(ip for ip in active_ips if clients.get(ip, 0) == 0)
unverified = sorted(set(low) | set(possible_bypass))
report_ips = observed_ips | modem_ips | query_ips
total = len(report_ips)
using = len(using_ips)
strict_total = len(active_ips)
strict_cov = round(100 * using / strict_total) if strict_total else 100
cov = strict_cov

if modem["fresh"]:
    inventory_state = f"fresh ({modem['age']}s)"
elif modem["present"]:
    inventory_state = f"stale ({modem['age']}s > {modem_stale_sec}s)"
else:
    inventory_state = "missing"
print(f"Modem envanter: {inventory_state} — {modem_path}")
print(f"LAN cihaz (ARP, gateway haric): {total} (REACHABLE/DELAY: {len(online_ips)}, idle STALE: {len(idle_ips)})")
if report_ips:
    print("  " + ", ".join(f"{ip}{host_label(ip)}" for ip in sorted(report_ips)))
print(f"Pi DNS dogrulanan (>={min_queries} sorgu, stale haric): {using}/{strict_total} (%{cov}) | rapor: {using}/{total}")
for ip in sorted(using_ips):
    proto = ",".join(sorted(protocols[ip])) or "api-unknown"
    print(f"  [USING_PI_DNS] {ip}{host_label(ip)} ({seen_label(ip)}): {clients[ip]} sorgu, {blocked.get(ip, 0)} engel, protokol={proto}")
for ip in low:
    print(f"  [POSSIBLE_BYPASS] {ip}{host_label(ip)} ({mac_for(ip)}, {seen_label(ip)}): {clients[ip]} sorgu — esik altinda")
for ip in possible_bypass:
    print(f"  [POSSIBLE_BYPASS] {ip}{host_label(ip)} ({mac_for(ip)}, {seen_label(ip)}): aktif gorunuyor, Pi DNS sorgusu yok")
for ip in stale_ips:
    print(f"  [STALE] {ip}{host_label(ip)} ({mac_for(ip)}, {seen_label(ip)}): aktiflik kaniti yok")
for ip in unknown_ips:
    print(f"  [UNKNOWN] {ip}{host_label(ip)} ({mac_for(ip)}, {seen_label(ip)}): modem snapshot'ta yok")
if ipv6_query_clients:
    print(
        "  [IPV6_DNS_QUERY] "
        + ", ".join(f"{ip} ({count} sorgu)" for ip, count in sorted(ipv6_query_clients.items()))
    )
else:
    print("  [UNKNOWN] IPv6 istemci query logu görünmedi; RDNSS kaynağı ayrı doğrulanmalı")
protocol_unknown = any("api-unknown" in values for values in protocols.values())
if protocol_unknown:
    print("  [UNKNOWN] AdGuard query log protokol alanı vermiyor; DoH/DoT/DoQ sonucu bu API'den çıkarılamaz")
if not netalert_db_readable:
    print("  [UNKNOWN] NetAlertX app.db okunamadi; online cihaz/isim kaniti eksik")

print("")
print("=== Olası nedenler (modem DNS tek basina yetmez) ===")
print("  1. Modemde WAN DNS degil LAN/DHCP DNS ayarlanmali")
print("  2. Ikincil DNS 8.8.8.8/1.1.1.1 olmasin (ZTE H3600P panel DNS2 yok sayilir, OFFER yine .1 basar)")
print("  3. Cihazlar eski DHCP lease — Wi-Fi kapat/ac veya reboot")
print("  4. Android Ozel DNS / iOS Private Relay kapali olmali")
print("  5. IPv6 DNS (modem RDNSS) Pi yerine baska sunucu verebilir")
print("  6. TV/konsol sabit DNS kullanabilir — elle Pi IP gir")
print("  7. [POSSIBLE_BYPASS] yalnızca ARP/query kaniti var; modem snapshot yoksa kesin bypass denmez")
print("  8. DoT (853) — modem filtre veya Android Ozel DNS kapali")
print("  9. Tarayici Secure DNS — Mac/PC make mac-dns; canary use-application-dns.net engelli olmali")
print("")
if unverified:
    print("=== Bypass cihazlar (hemen) ===")
    for ip in unverified:
        print(f"  * {ip}{host_label(ip)}: Wi-Fi kapat/ac veya reboot; DNS elle {pi_ip}")
    print("  * Android: Ayarlar → Ag → Ozel DNS → Kapali")
    print("  * iOS: Ayarlar → Apple ID → iCloud → Ozel Relay kapali")
    print("  * Mac: make mac-dns")
print("")
print("=== Cozum secenekleri ===")
print("  A) Modem: DHCP DNS1={} DNS2=BOS + tum cihaz reboot".format(pi_ip))
print("  B) NETWORK_MODE=adguard-dhcp — ZTE H3600P'te DENEME (relay DISCOVER yutuyor); baska modem + UFW UDP/67")
print("  C) Ethernet+WiFi: kablolu NIC public DNS WAN :53 drop keser — Mac: make mac-dns")
print("  D) IPv6: radvd 3–4s + modem LL lifetime 0; modem RA 900s last-RA. Anlamazsa make mac-dns")

def write_state(status, exit_code):
    path = os.environ.get(
        "ADGUARD_DNS_COVERAGE_STATE_PATH",
        "/var/lib/pi-gateway/dns-coverage-state.json",
    )
    payload = {
        "ts": datetime.fromtimestamp(now_ts, timezone.utc).isoformat(),
        "status": status,
        "exit_code": exit_code,
        "coverage_percent": strict_cov,
        "active_devices": strict_total,
        "using_pi_dns": using,
        "reported_devices": total,
        "unverified_devices": len(unverified),
        "inventory_fresh": bool(modem["fresh"]),
        "netalert_db_readable": bool(netalert_db_readable),
        "ipv6_query_clients": len(ipv6_query_clients),
        "protocol_unknown": bool(protocol_unknown),
    }
    tmp_path = None
    try:
        directory = os.path.dirname(path) or "."
        os.makedirs(directory, exist_ok=True)
        fd, tmp_path = tempfile.mkstemp(prefix=".dns-coverage-", dir=directory)
        with os.fdopen(fd, "w", encoding="utf-8") as fh:
            json.dump(payload, fh, ensure_ascii=False)
            fh.write("\n")
        os.replace(tmp_path, path)
    except OSError as exc:
        if tmp_path:
            try:
                os.unlink(tmp_path)
            except OSError:
                pass
        print(f"[WARN] DNS coverage state yazilamadi: {exc}", file=sys.stderr)


def finish(status, exit_code):
    write_state(status, exit_code)
    sys.exit(exit_code)


if bypass_check == "off":
    print("COVERAGE_OK")
    finish("off", 0)
inventory_unknown = modem_required and not modem["fresh"]
if inventory_unknown:
    print("COVERAGE_UNKNOWN: modem snapshot missing or stale")
    finish("unknown", 12)
if modem_required and modem["fresh"] and unknown_ips:
    print("UNKNOWN_DEVICES:" + ",".join(unknown_ips))
    finish("unknown", 12)
if strict_total and strict_cov < min_cov:
    print(f"COVERAGE_FAIL:{strict_cov}")
    finish("fail", 10)
if unverified:
    print("MISSING_DEVICES:" + ",".join(unverified))
    finish("warn" if bypass_check == "warn" else "fail", 11)
if protocol_unknown:
    print("COVERAGE_OK")
    finish("warn", 0)
print("COVERAGE_OK")
finish("ok", 0)
PY
rc=$?
set -e
case "$rc" in
  0)
    case "$(coverage_state_status)" in
      ok)
        note_ok "DNS kapsami yeterli"
        ;;
      warn)
        note_warn "DNS kapsami PASS degil — evidence WARN (protokol/bypass kaniti eksik olabilir)"
        ;;
      fail)
        note_fail "DNS kapsami FAIL — state/exit kodu uyumsuz"
        ;;
      *)
        note_warn "DNS kapsami sonucu UNKNOWN — coverage state okunamadi veya stale"
        ;;
    esac
    ;;
  10|11)
    if [[ "$BYPASS_CHECK" == "warn" ]]; then
      note_warn "DNS kapsami dusuk — bazi cihazlar Pi DNS kullanmiyor"
    else
      note_fail "DNS kapsami dusuk — bazi cihazlar Pi DNS kullanmiyor"
      fail=1
    fi
    ;;
  12)
    if [[ "$BYPASS_CHECK" == "warn" ]]; then
      note_warn "DNS kapsami kesinlestirilemedi — modem envanteri veya cihaz gorunurlugu eksik"
    else
      note_fail "DNS kapsami kesinlestirilemedi — modem snapshot/cihaz kaydi UNKNOWN"
      fail=1
    fi
    ;;
  *)
    note_fail "audit script hatasi (exit $rc)"
    fail=1
    ;;
esac
exit "$fail"
