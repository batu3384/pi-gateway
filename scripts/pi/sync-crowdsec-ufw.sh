#!/usr/bin/env bash
# CrowdSec aktif ban kararlarini UFW'ye senkronize eder (ekle + suresi dolani sil)
set -euo pipefail

docker ps --format '{{.Names}}' | grep -qx 'crowdsec' || exit 0
command -v ufw >/dev/null 2>&1 || exit 0

decisions_json="$(docker exec crowdsec cscli decisions list -o json 2>/dev/null || echo '[]')"
ufw_numbered="$(sudo ufw status numbered 2>/dev/null || true)"

eval "$(python3 - "$decisions_json" "$ufw_numbered" <<'PY'
import ipaddress
import json
import re
import shlex
import sys

raw_dec, raw_ufw = sys.argv[1], sys.argv[2]
try:
    items = json.loads(raw_dec) or []
except json.JSONDecodeError:
    items = []

active = set()
if isinstance(items, list):
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
            if net.num_addresses == 1:
                active.add(str(net.network_address))
            else:
                active.add(str(net))

existing_active = set()
delete_nums = []
rule_re = re.compile(r"^\[\s*(\d+)\].*?\bDENY IN\s+([0-9a-fA-F:.]+(?:/\d+)?)\b.*#\s*(crowdsec(?:-sync)?)\s*$")
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
print("TO_DEL=(" + " ".join(shlex.quote(str(n)) for n in to_del) + ")")
print("TO_ADD=(" + " ".join(shlex.quote(ip) for ip in to_add) + ")")
PY
)"

for num in "${TO_DEL[@]:-}"; do
  [[ -n "$num" ]] || continue
  sudo ufw --force delete "$num" >/dev/null 2>&1 || true
done

for ip in "${TO_ADD[@]:-}"; do
  [[ -n "$ip" ]] || continue
  sudo ufw insert 1 deny from "$ip" to any comment 'crowdsec-sync' >/dev/null 2>&1 || true
done
