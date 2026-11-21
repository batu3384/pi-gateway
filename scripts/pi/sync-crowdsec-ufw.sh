#!/usr/bin/env bash
# CrowdSec aktif ban kararlarini UFW'ye senkronize eder (ekle + suresi dolani sil)
set -euo pipefail

REMOTE_DIR="${REMOTE_DIR:-/home/${USER}/pi-gateway}"
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
_PG_ENV_LIB="${SCRIPT_DIR}/../lib/env-file.sh"
if [[ -f "$_PG_ENV_LIB" ]]; then
  # shellcheck source=../lib/env-file.sh
  source "${_PG_ENV_LIB}"
  read_remote_dotenv || true
fi

docker ps --format '{{.Names}}' | grep -qx 'crowdsec' || exit 0
command -v ufw >/dev/null 2>&1 || exit 0

LOCK_FILE="/run/pi-gateway/crowdsec-ufw.lock"
mkdir -p /run/pi-gateway 2>/dev/null || sudo mkdir -p /run/pi-gateway 2>/dev/null || true
exec 9>"$LOCK_FILE" 2>/dev/null || true
flock -n 9 2>/dev/null || exit 0

# Fail-closed: cscli hata/timeout verirse mevcut UFW banlarini ASLA silme
if ! decisions_json="$(timeout 15 docker exec crowdsec cscli decisions list -o json 2>/dev/null)"; then
  echo "[sync-crowdsec-ufw] WARN: cscli decisions list basarisiz — UFW kurallari korundu" >&2
  exit 0
fi
[[ -n "${decisions_json:-}" ]] || decisions_json="[]"
ufw_numbered="$(sudo ufw status numbered 2>/dev/null || true)"

eval "$(python3 - "$decisions_json" "$ufw_numbered" \
  "${PI_STATIC_IP:-}" "${LAN_GATEWAY:-}" "${LAN_SUBNET_CIDR:-}" <<'PY'
import ipaddress
import json
import re
import shlex
import sys

raw_dec, raw_ufw, pi_ip, lan_gw, lan_cidr = sys.argv[1:6]
try:
    parsed = json.loads(raw_dec)
except json.JSONDecodeError:
    print("CSCLI_INVALID=1")
    sys.exit(0)

if parsed is None:
    items = []
elif isinstance(parsed, list):
    items = parsed
else:
    print("CSCLI_INVALID=1")
    sys.exit(0)

safelist_nets = [
    ipaddress.ip_network("127.0.0.0/8"),
    ipaddress.ip_network("::1/128"),
    ipaddress.ip_network("100.64.0.0/10"),
    ipaddress.ip_network("169.254.0.0/16"),
    ipaddress.ip_network("fe80::/10"),
]
for raw_safe in (pi_ip, lan_gw, lan_cidr):
    val = (raw_safe or "").strip()
    if not val:
        continue
    try:
        safelist_nets.append(ipaddress.ip_network(val, strict=False))
    except ValueError:
        pass


def is_safe_or_overbroad(net) -> bool:
    if net.version == 4 and net.prefixlen < 16:
        return True
    if net.version == 6 and net.prefixlen < 48:
        return True
    for safe in safelist_nets:
        if safe.version == net.version and (net.overlaps(safe)):
            return True
    return False


active = set()
for alert in items:
    if not isinstance(alert, dict):
        continue
    decs = alert.get("decisions")
    if not isinstance(decs, list):
        decs = [alert]
    for dec in decs:
        if not isinstance(dec, dict):
            continue
        if str(dec.get("type", "")).lower() != "ban":
            continue
        val = str(dec.get("value") or "").strip()
        if not val:
            continue
        try:
            net = ipaddress.ip_network(val, strict=False)
        except ValueError:
            continue
        if is_safe_or_overbroad(net):
            continue
        if net.num_addresses == 1:
            active.add(str(net.network_address))
        else:
            active.add(str(net))

existing_active = set()
delete_nums = []
# Trailing \b yok — IPv6 '::' ile biten adreslerde (2001:db8::) eslesmeyi koru
rule_re = re.compile(
    r"^\[\s*(\d+)\].*?\bDENY IN\s+([0-9a-fA-F:.]+(?:/\d+)?)(?=\s).*#\s*(crowdsec(?:-sync)?)\s*$"
)
for line in raw_ufw.splitlines():
    m = rule_re.match(line.strip())
    if not m:
        continue
    num, src, comment = m.group(1), m.group(2), m.group(3)
    try:
        net = ipaddress.ip_network(src, strict=False)
        norm = str(net.network_address) if net.num_addresses == 1 else str(net)
    except ValueError:
        norm = src
    if comment == "crowdsec-sync" and norm in active:
        existing_active.add(norm)
    else:
        delete_nums.append(int(num))

to_add = sorted(active - existing_active)
to_del = sorted(delete_nums, reverse=True)
print("CSCLI_INVALID=0")
print("TO_DEL=(" + " ".join(shlex.quote(str(n)) for n in to_del) + ")")
print("TO_ADD=(" + " ".join(shlex.quote(ip) for ip in to_add) + ")")
PY
)"

[[ "${CSCLI_INVALID:-0}" -eq 0 ]] || exit 0

for num in "${TO_DEL[@]:-}"; do
  [[ -n "$num" ]] || continue
  sudo ufw --force delete "$num" >/dev/null 2>&1 || true
done

for ip in "${TO_ADD[@]:-}"; do
  [[ -n "$ip" ]] || continue
  # prepend: IPv4 ve IPv6 tablolarinin ikisinde de basa ekler (insert 1 IPv6'da kirilir)
  sudo ufw prepend deny from "$ip" to any comment 'crowdsec-sync' >/dev/null 2>&1 || true
done
