#!/usr/bin/env bash
# Agi otomatik ag kesfi - Pi uzerinde calisir
set -euo pipefail

IF="${PI_INTERFACE:-eth0}"

if ! ip link show "$IF" >/dev/null 2>&1; then
  IF="$(ip -4 route show default | awk '{print $5; exit}')"
fi

GATEWAY="$(ip -4 route show default dev "$IF" | awk '{print $3; exit}')"
CURRENT_IP="$(ip -4 addr show dev "$IF" | awk '/inet / {print $2; exit}')"

python3 - "$GATEWAY" "$CURRENT_IP" "$IF" <<'PY'
import ipaddress, sys
gateway = sys.argv[1]
ip_cidr = sys.argv[2]
iface = sys.argv[3]
iface_addr = ipaddress.ip_interface(ip_cidr)
net = iface_addr.network
hosts = list(net.hosts())
gateway_ip = ipaddress.ip_address(gateway)
candidates = [h for h in hosts if h != gateway_ip]
static = iface_addr.ip
start = candidates[20] if len(candidates) > 30 else candidates[10]
end = candidates[-20] if len(candidates) > 40 else candidates[-5]
print(f"PI_INTERFACE={iface}")
print(f"LAN_GATEWAY={gateway}")
print(f"LAN_SUBNET_CIDR={net.with_prefixlen}")
print(f"LAN_PREFIX={net.prefixlen}")
print(f"LAN_SUBNET_MASK={net.netmask}")
print(f"PI_STATIC_IP={static}")
print(f"PI_HOST={static}")
print(f"DHCP_RANGE_START={start}")
print(f"DHCP_RANGE_END={end}")
PY
