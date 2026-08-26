#!/usr/bin/env bash
# Router DHCP DNS offer sniff (nmap, sonra sahte-MAC DISCOVER). Source or run standalone.
set -euo pipefail

# _dhcp_offer_python <pi_ip> [iface] → stdout: "DNS a,b" / "Router x" ; rc 0/2
_dhcp_offer_python() {
  sudo python3 - "$1" "${2:-eth0}" <<'PY'
import os, socket, sys
iface = sys.argv[2] if len(sys.argv) > 2 else "eth0"
xid = os.urandom(4)
mac = bytes.fromhex("02000000d9c1")
pkt = bytearray(236)
pkt[0:4] = b"\x01\x01\x06\x00"
pkt[4:8] = xid
pkt[10:12] = b"\x80\x00"
pkt[28:34] = mac
pkt += b"\x63\x82\x53\x63"
pkt += bytes([53, 1, 1, 61, 7, 1]) + mac + bytes([55, 4, 1, 3, 6, 15, 255])
s = socket.socket(socket.AF_INET, socket.SOCK_DGRAM)
s.setsockopt(socket.SOL_SOCKET, socket.SO_BROADCAST, 1)
s.setsockopt(socket.SOL_SOCKET, socket.SO_REUSEADDR, 1)
# Linux: eth0'a bagla (multi-NIC'te yanlis iface'e dusmesin)
if hasattr(socket, "SO_BINDTODEVICE"):
    try:
        s.setsockopt(socket.SOL_SOCKET, socket.SO_BINDTODEVICE, iface.encode() + b"\0")
    except OSError:
        pass
try:
    s.bind(("0.0.0.0", 68))
except OSError:
    sys.exit(2)
s.settimeout(6)
try:
    s.sendto(bytes(pkt), ("255.255.255.255", 67))
    data, _ = s.recvfrom(2048)
except (socket.timeout, OSError):
    sys.exit(2)
finally:
    s.close()
magic = data.find(b"\x63\x82\x53\x63")
opts = data[magic + 4 :] if magic >= 0 else b""
i = 0
dns, router = [], ""
while i < len(opts) and opts[i] != 255:
    t = opts[i]
    if t == 0:
        i += 1
        continue
    ln = opts[i + 1]
    v = opts[i + 2 : i + 2 + ln]
    if t == 6:
        dns = [".".join(map(str, v[j : j + 4])) for j in range(0, len(v), 4)]
    if t == 3 and len(v) >= 4:
        router = ".".join(map(str, v[:4]))
    i += 2 + ln
if not dns:
    sys.exit(2)
print("DNS " + ",".join(dns))
if router:
    print("Router " + router)
PY
}

# check_dhcp_dns_offer <pi_ip> [gateway_ip] [iface]
# Exit 0 = OK, 1 = fail, 2 = sniff unavailable
check_dhcp_dns_offer() {
  local pi_ip="$1"
  local gateway_ip="${2:-}"
  local iface="${3:-${PI_INTERFACE:-eth0}}"
  local out dns_line router_line dns_list r
  local nmap_timeout="${DHCP_DNS_NMAP_TIMEOUT_SEC:-20}"

  dns_line=""
  router_line=""
  # nmap broadcast-dhcp-discover bu LAN'da bos; adguard-dhcp = python DISCOVER
  if [[ "${NETWORK_MODE:-router-dns}" != "adguard-dhcp" ]] && command -v nmap &>/dev/null; then
    local run_nmap=(nmap --script broadcast-dhcp-discover --script-timeout "${nmap_timeout}s")
    if [[ -n "$iface" ]] && ip link show "$iface" &>/dev/null; then
      run_nmap+=(-e "$iface")
    fi
    if command -v timeout &>/dev/null; then
      out="$(sudo timeout "$nmap_timeout" "${run_nmap[@]}" 2>/dev/null || true)"
    elif command -v gtimeout &>/dev/null; then
      out="$(sudo gtimeout "$nmap_timeout" "${run_nmap[@]}" 2>/dev/null || true)"
    else
      out="$(sudo "${run_nmap[@]}" 2>/dev/null || true)"
    fi
    dns_line="$(grep -E 'Domain Name Server' <<<"$out" | head -1 || true)"
    router_line="$(grep -E 'Router:' <<<"$out" | head -1 || true)"
  fi

  if [[ -z "$dns_line" ]]; then
    out="$(_dhcp_offer_python "$pi_ip" "$iface" 2>/dev/null || true)"
    dns_line="$(grep -E '^DNS ' <<<"$out" | head -1 || true)"
    router_line="$(grep -E '^Router ' <<<"$out" | head -1 || true)"
    if [[ -z "$dns_line" ]]; then
      echo "[dhcp-dns] HATA: DHCP OFFER alinamadi (nmap/python sniff)"
      return 2
    fi
    echo "[dhcp-dns] python DISCOVER (nmap bos)"
  fi

  dns_list="${dns_line#*: }"
  dns_list="${dns_list#DNS }"
  dns_list="${dns_list//,/ }"
  echo "[dhcp-dns] OFFER DNS: ${dns_list}"
  if [[ -n "$router_line" ]]; then
    r="${router_line#*: }"
    r="${r#Router }"
    echo "[dhcp-dns] Router: $r"
  fi

  local first="${dns_list%% *}"
  if [[ "$first" != "$pi_ip" ]]; then
    echo "[dhcp-dns] HATA: birincil DNS ${first:-?} != Pi (${pi_ip})"
    return 1
  fi

  local bad=0 ip
  for ip in $dns_list; do
    case "$ip" in
      1.1.1.1|1.0.0.1|8.8.8.8|8.8.4.4|9.9.9.9|208.67.222.222)
        echo "[dhcp-dns] HATA: dis DNS bypass: $ip"
        bad=1
        ;;
    esac
  done
  [[ "$bad" -eq 0 ]] || return 1

  if [[ -n "$gateway_ip" ]] && grep -qw "$gateway_ip" <<<"$dns_list"; then
    if [[ "${NETWORK_MODE:-router-dns}" == "adguard-dhcp" ]]; then
      echo "[dhcp-dns] HATA: adguard-dhcp OFFER hâlâ modem DNS ($gateway_ip)"
      return 1
    fi
    echo "[dhcp-dns] UYARI: ikincil DNS modem ($gateway_ip) — Pi down olursa cihaz fallback bypass (ZTE sik ekler; panel DNS2 yok sayilir)"
    echo "[dhcp-dns] NOT: dis DNS (1.1.1.1/8.8.8.8) degil — modem resolver reklam engellemez; diagnose FAIL degil"
  fi

  echo "[dhcp-dns] OK: birincil DNS Pi"
  return 0
}

if [[ "${BASH_SOURCE[0]}" == "${0}" ]]; then
  SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
  # shellcheck source=env-file.sh
  source "$SCRIPT_DIR/env-file.sh"
  read_remote_dotenv 2>/dev/null || true
  PI_IP="${PI_STATIC_IP:-${1:-}}"
  GATEWAY="${LAN_GATEWAY:-${2:-}}"
  IFACE="${PI_INTERFACE:-eth0}"
  [[ -n "$PI_IP" ]] || { echo "[dhcp-dns] PI_STATIC_IP gerekli" >&2; exit 2; }
  check_dhcp_dns_offer "$PI_IP" "$GATEWAY" "$IFACE"
fi
