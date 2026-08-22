#!/usr/bin/env bash
# Router DHCP DNS offer sniff (nmap broadcast-dhcp-discover). Source or run standalone.
set -euo pipefail

# check_dhcp_dns_offer <pi_ip> [gateway_ip] [iface]
# Exit 0 = OK, 1 = fail, 2 = nmap/sniff unavailable
check_dhcp_dns_offer() {
  local pi_ip="$1"
  local gateway_ip="${2:-}"
  local iface="${3:-${PI_INTERFACE:-eth0}}"
  local out dns_line router_line dns_list
  local nmap_timeout="${DHCP_DNS_NMAP_TIMEOUT_SEC:-20}"

  command -v nmap &>/dev/null || return 2
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

  if [[ -z "$dns_line" ]]; then
    echo "[dhcp-dns] HATA: DHCP OFFER alinamadi (nmap sniff)"
    return 2
  fi

  dns_list="${dns_line#*: }"
  dns_list="${dns_list//,/ }"
  echo "[dhcp-dns] OFFER DNS: ${dns_list}"
  [[ -n "$router_line" ]] && echo "[dhcp-dns] Router: ${router_line#*: }"

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
    echo "[dhcp-dns] UYARI: ikincil DNS modem ($gateway_ip) — Pi down olursa cihaz fallback bypass (ZTE sik ekler; panelde silinmez)"
    echo "[dhcp-dns] NOT: dis DNS (1.1.1.1/8.8.8.8) degil — soft risk, diagnose FAIL degil"
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
