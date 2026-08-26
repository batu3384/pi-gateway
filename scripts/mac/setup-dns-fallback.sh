#!/usr/bin/env bash
# macOS: LAN DNS = Pi. Public yedek (1.1.1.1/8.8.8.8) WAN dest:53 drop ile timeout — internet "ölür".
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=../lib/common.sh
source "$SCRIPT_DIR/../lib/common.sh"
load_env

PI_DNS="${PI_STATIC_IP:-}"
FALLBACK_DNS="${ROUTER_DNS_SECONDARY:-}"

log() { echo "[dns-fallback] $*"; }

[[ "$(uname)" == "Darwin" ]] || { log "Sadece macOS"; exit 1; }
[[ -n "$PI_DNS" ]] || die "PI_STATIC_IP gerekli (.env)"

is_public_dns() {
  case "$1" in
    1.1.1.1|1.0.0.1|8.8.8.8|8.8.4.4|9.9.9.9|208.67.222.222|208.67.220.220) return 0 ;;
    *) return 1 ;;
  esac
}

if [[ -n "$FALLBACK_DNS" ]] && is_public_dns "$FALLBACK_DNS"; then
  log "ROUTER_DNS_SECONDARY=$FALLBACK_DNS public — WAN :53 drop timeout. LAN_GATEWAY kullan."
  FALLBACK_DNS=""
fi
# false: modem .1 yok (reklam kilit). true: Pi down yedek, LAN :53 sızıntı.
if [[ "${MAC_DNS_GATEWAY_FALLBACK:-false}" != "true" ]]; then
  FALLBACK_DNS=""
  log "MAC_DNS_GATEWAY_FALLBACK=false — DNS = Pi+ULA, modem yok."
elif [[ -z "$FALLBACK_DNS" ]]; then
  FALLBACK_DNS="${LAN_GATEWAY:-}"
fi

dns_args=("$PI_DNS")
ula="${PI_IPV6_ULA:-}"
ula="${ula%%/*}"
if [[ -n "$ula" ]]; then
  dns_args+=("$ula")
fi
if [[ -n "$FALLBACK_DNS" && "$FALLBACK_DNS" != "$PI_DNS" ]]; then
  dns_args+=("$FALLBACK_DNS")
fi

# PI_INTERFACE=eth0 Pi'nin NIC'i — Mac'te eth0 yok. Yalnızca Ethernet/Wi-Fi.
lan_hw_services() {
  local svc
  while IFS= read -r svc; do
    [[ "$svc" == *"*"* ]] && continue
    case "$svc" in
      Ethernet|Wi-Fi|"USB Ethernet"|"USB LAN"|"Thunderbolt Ethernet")
        printf '%s\n' "$svc"
        ;;
    esac
  done < <(networksetup -listallnetworkservices 2>/dev/null | tail -n +2)
}

SERVICES=()
while IFS= read -r svc; do
  SERVICES+=("$svc")
done < <(lan_hw_services)
[[ ${#SERVICES[@]} -gt 0 ]] || die "Ethernet/Wi-Fi servisi bulunamadi"

MODE="${1:-apply}"
LAN_CIDR="${LAN_SUBNET_CIDR:-}"
if [[ -z "$LAN_CIDR" && "$PI_DNS" == *.*.*.* ]]; then
  LAN_CIDR="${PI_DNS%.*}.0/24"
fi

svc_ipv4() {
  networksetup -getinfo "$1" 2>/dev/null | awk -F': ' '/^IP address:/{print $2; exit}'
}

ipv4_in_lan() {
  local ip="$1"
  [[ -n "$ip" && "$ip" != "none" && -n "$LAN_CIDR" ]] || return 1
  python3 -c 'import ipaddress,sys
try:
    ip=ipaddress.ip_address(sys.argv[1])
    net=ipaddress.ip_network(sys.argv[2], strict=False)
except Exception:
    raise SystemExit(1)
raise SystemExit(0 if ip in net else 1)' "$ip" "$LAN_CIDR"
}

svc_has_pi_dns() {
  local cur
  cur="$(networksetup -getdnsservers "$1" 2>/dev/null || true)"
  [[ "$cur" == *"$PI_DNS"* ]] && return 0
  [[ -n "$ula" && "$cur" == *"$ula"* ]] && return 0
  return 1
}

set_svc_dns() {
  local svc="$1" err
  shift
  if sudo -n true 2>/dev/null; then
    sudo networksetup -setdnsservers "$svc" "$@"
    return 0
  fi
  err="$(networksetup -setdnsservers "$svc" "$@" 2>&1)" && return 0
  log "networksetup fail ($svc): ${err:-unknown}"
  log "sudo: sudo networksetup -setdnsservers '$svc' $*"
  return 1
}

active=0
ifconfig en0 2>/dev/null | grep -q 'status: active' && active=$((active + 1))
ifconfig en1 2>/dev/null | grep -q 'status: active' && active=$((active + 1))
fail_dns=0
applied=0
for svc in "${SERVICES[@]}"; do
  ip4="$(svc_ipv4 "$svc")"
  if [[ "$MODE" == "clear" ]]; then
    log "Mac DNS: $svc -> empty (clear)"
    set_svc_dns "$svc" empty || fail_dns=1
    continue
  fi
  # Hotspot / yabancı ağ: Pi+ULA yazma (ULA route yok → AAAA timeout, YouTube DoH hariç site ölür).
  if ipv4_in_lan "$ip4"; then
    log "Mac DNS: $svc ($ip4) -> ${dns_args[*]}"
    set_svc_dns "$svc" "${dns_args[@]}" || fail_dns=1
    applied=$((applied + 1))
  elif svc_has_pi_dns "$svc"; then
    log "Mac DNS: $svc (${ip4:-none}) LAN degil — leftover Pi/ULA silindi"
    set_svc_dns "$svc" empty || fail_dns=1
  else
    log "Mac DNS: $svc (${ip4:-none}) LAN degil — atlandi"
  fi
done

if (( active > 1 )); then
  log "UYARI: Ethernet+WiFi ayni anda aktif — OS kabloyu tercih eder. Birini kapat veya ikisinde de Pi DNS (bu script)."
fi

sudo -n dscacheutil -flushcache 2>/dev/null || true
sudo -n killall -HUP mDNSResponder 2>/dev/null || true

log ""
if [[ "$MODE" == "clear" ]]; then
  log "DNS DHCP'ye birakildi (empty)."
elif (( applied == 0 )); then
  log "Hic LAN servisi yok — Pi DNS yazilmadi. Ev Wi-Fi/Ethernet sonrasi: make mac-dns"
else
  log "Manuel DNS RDNSS fe80::1 (modem) ezer — reklam Pi'den gecer."
  log "Yedek = ${FALLBACK_DNS:-yok} (MAC_DNS_GATEWAY_FALLBACK=${MAC_DNS_GATEWAY_FALLBACK:-false})."
fi
log ""

if (( applied > 0 )); then
  if dig +time=3 +tries=1 @"$PI_DNS" google.com A +short >/dev/null 2>&1; then
    log "Test OK: Pi DNS yanit veriyor"
  else
    log "UYARI: Pi DNS su an yanit vermiyor"
  fi
fi
[[ "$fail_dns" -eq 0 ]] || exit 1
