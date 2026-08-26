#!/usr/bin/env bash
# Reklam engelleme / DNS bypass teşhisi
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
# shellcheck source=../lib/dhcp-dns-offer.sh
source "$SCRIPT_DIR/../lib/dhcp-dns-offer.sh"
PI_IP="${PI_STATIC_IP:-}"
ADGUARD_WEB_PORT="${ADGUARD_WEB_PORT:-8080}"
AGH_ADMIN_USER="${AGH_ADMIN_USER:-admin}"
AGH_ADMIN_PASSWORD="${AGH_ADMIN_PASSWORD:-}"
ok=0
fail_count=0
api_ok=false
pass() { echo "[OK] $*"; ok=$((ok + 1)); }
fail() { echo "[FAIL] $*"; fail_count=$((fail_count + 1)); }
warn() { echo "[WARN] $*"; }

test_blocked() {
  local domain="$1" a aaaa
  a="$(dig +time=2 +tries=1 @"${PI_IP}" "$domain" A 2>/dev/null || true)"
  echo "$a" | grep -Eq '0\.0\.0\.0|127\.0\.0\.0|NXDOMAIN' || return 1
  aaaa="$(dig +time=2 +tries=1 +short @"${PI_IP}" "$domain" AAAA 2>/dev/null || true)"
  aaaa="${aaaa%%$'\n'*}"
  [[ -z "$aaaa" || "$aaaa" == "::" || "$aaaa" == "::1" ]]
}

echo "=== Reklam engelleme (DNS) teşhisi ==="
echo "NETWORK_MODE=${NETWORK_MODE:-router-dns} ADGUARD_FILTER_PROFILE=${ADGUARD_FILTER_PROFILE:-balanced}"
for domain in doubleclick.net googlesyndication.com samsungads.com; do
  if test_blocked "$domain"; then
    pass "Pi DNS ${domain} engelliyor"
  else
    fail "Pi DNS ${domain} engellemiyor"
  fi
done
# 8.8.8.8 UDP modem IP filtresinde timeout olabilir — bos cevap ≠ 0.0.0.0
_google_err="$(dig +time=1 +tries=1 @8.8.8.8 doubleclick.net A 2>&1 || true)"
if grep -qiE 'timed out|no servers could be reached|communications error' <<<"$_google_err"; then
  pass "8.8.8.8 UDP timeout (modem IP filtresi)"
  _alt_err="$(dig +time=1 +tries=1 @8.8.4.4 doubleclick.net A 2>&1 || true)"
  _alt_out="$(dig +time=1 +tries=1 +short @8.8.4.4 doubleclick.net A 2>/dev/null || true)"
  if grep -qiE 'timed out|no servers could be reached|communications error' <<<"$_alt_err"; then
    pass "8.8.4.4 de timeout — drop 8.8.4.4 da var"
  elif [[ -n "$_alt_out" ]] && grep -qv '0.0.0.0' <<<"$_alt_out"; then
    fail "8.8.4.4 :53 acik — dest bos kural eksik (yalniz 8.8.8.8 /32)"
  else
    warn "8.8.4.4 karsilastirma belirsiz"
  fi
elif dig +short @8.8.8.8 doubleclick.net A 2>/dev/null | grep -qv '0.0.0.0'; then
  fail "8.8.8.8 :53 acik — dest bos kural yok"
else
  warn "Google DNS 0.0.0.0 veya bos — beklenmeyen"
fi
unset _google_err _alt_err _alt_out
for _pub in 1.0.0.1 9.9.9.9; do
  _e="$(dig +time=1 +tries=1 @"$_pub" example.com A 2>&1 || true)"
  if grep -qiE 'timed out|no servers could be reached|communications error' <<<"$_e"; then
    pass "${_pub} :53 timeout (WAN drop)"
  else
    fail "${_pub} :53 acik — dest bos veya CIDR yok"
  fi
done
unset _pub _e
if [[ -n "$AGH_ADMIN_PASSWORD" ]]; then
  COOKIE="$(mktemp)"
  trap 'rm -f "$COOKIE"' EXIT
  if agh_login "http://127.0.0.1:${ADGUARD_WEB_PORT}" "$COOKIE" "$AGH_ADMIN_USER" "$AGH_ADMIN_PASSWORD" 2>/dev/null; then
    api_ok=true
    stats="$(curl -fsS -b "$COOKIE" "http://127.0.0.1:${ADGUARD_WEB_PORT}/control/stats")"
    python3 -c "
import json,sys
s=json.loads(sys.argv[1])
q=s.get('num_dns_queries',0)
b=s.get('num_blocked_filtering',0)
print(f'[OK] AdGuard: {b}/{q} engellendi ({round(100*b/max(1,q),1)}%)')
" "$stats"
    ok=$((ok + 1))
    enabled="$(curl -fsS -b "$COOKIE" "http://127.0.0.1:${ADGUARD_WEB_PORT}/control/filtering/status" | python3 -c "import json,sys; print(sum(1 for f in json.load(sys.stdin).get('filters',[]) if f.get('enabled')))")"
    rules="$(curl -fsS -b "$COOKIE" "http://127.0.0.1:${ADGUARD_WEB_PORT}/control/filtering/status" | python3 -c "import json,sys; print(sum((f.get('rules_count') or 0) for f in json.load(sys.stdin).get('filters',[])))")"
    pass "${enabled} filtre listesi aktif (${rules} kural)"
    [[ "${rules:-0}" -ge "${ADGUARD_MIN_FILTER_RULES:-100000}" ]] || fail "filtre kural sayisi dusuk (${rules:-0} < ${ADGUARD_MIN_FILTER_RULES:-100000})"
  else
    fail "AdGuard API login"
  fi
fi
echo ""
echo "=== DNS kapsam (ARP vs query log) ==="
if [[ "$api_ok" == "true" && "${ADGUARD_SKIP_BYPASS_CHECK:-false}" != "true" ]]; then
  if REMOTE_DIR="$REMOTE_DIR" bash "$SCRIPT_DIR/audit-dns-coverage.sh"; then
    pass "DNS kapsam auditi gecti"
  else
    fail "DNS kapsam auditi — bazi cihazlar Pi DNS kullanmiyor"
  fi
fi
echo ""
echo "=== DoH bypass listesi ==="
if test_blocked "dns.google" || test_blocked "dns.google.com"; then
  pass "DoH host (dns.google) engelleniyor"
else
  fail "DoH host engellenmiyor — HaGeZi doh listesi eksik olabilir"
fi

echo ""
echo "=== IPv6 ULA DNS ==="
ULA="${PI_IPV6_ULA:-}"
ULA="${ULA%%/*}"
if [[ -z "$ULA" ]]; then
  warn "PI_IPV6_ULA yok — IPv6 DNS sabiti tanimsiz"
elif ! ip -6 addr show | grep -F "$ULA" >/dev/null; then
  fail "ULA $ULA hostta yok — ensure-ipv6-ula.sh calistir"
elif dig +time=2 +tries=1 @"$ULA" cloudflare.com A >/dev/null 2>&1; then
  pass "ULA DNS cevap veriyor ($ULA)"
  if dig +time=2 +tries=1 @"$ULA" dns.google A 2>/dev/null | grep -Eq '0\.0\.0\.0|127\.0\.0\.0|NXDOMAIN'; then
    pass "ULA uzerinden DoH host engelleniyor"
  else
    warn "ULA acik ama dns.google engellenmedi (filtre henuz yenilenmemis olabilir)"
  fi
  if systemctl is-active --quiet radvd 2>/dev/null; then
    if grep -q 'AdvRDNSSLifetime 0' /etc/radvd.conf 2>/dev/null; then
      pass "radvd RFC 8106 modem RDNSS lifetime 0"
    else
      warn "radvd var ama modem RDNSS lifetime 0 yok (setup-rdnss-ra.sh)"
    fi
  else
    warn "radvd yok — LAN cihazlari IPv6 DNS olarak modem fe80::1 kullanabilir (setup-rdnss-ra.sh)"
  fi
else
  fail "ULA $ULA DNS cevap vermiyor (ufw/AdGuard IPv6)"
fi
echo ""
echo "=== Modem DHCP DNS (sniff) ==="
GATEWAY_IP="${LAN_GATEWAY:-${PI_IP%.*}.1}"
if check_dhcp_dns_offer "$PI_IP" "$GATEWAY_IP" "${PI_INTERFACE:-eth0}"; then
  pass "Modem DHCP birincil DNS = Pi"
else
  rc=$?
  if [[ "$rc" -eq 2 ]]; then
    warn "Modem DHCP sniff yapilamadi (nmap yok veya OFFER alinamadi)"
  else
    fail "Modem DHCP DNS Pi'ye isaret etmiyor veya dis DNS var"
  fi
fi
# DHCP DNS2=.1: WAN dest:53 ve LAN-ingress dest .1:53 FORWARD; modem INPUT :53 cevaplar.
_mod_a="$(dig +time=2 +tries=1 +short @"$GATEWAY_IP" doubleclick.net A 2>/dev/null || true)"
_mod_a="${_mod_a%%$'\n'*}"
if [[ -n "$_mod_a" && "$_mod_a" != "0.0.0.0" && "$_mod_a" != "127.0.0.0" ]]; then
  warn "Modem ${GATEWAY_IP} A reklam kaciriyor (${_mod_a}) — INPUT :53 (FORWARD filtre yetmez) / DHCP DNS2"
fi
_mod_aaaa="$(dig +time=2 +tries=1 +short @"$GATEWAY_IP" doubleclick.net AAAA 2>/dev/null || true)"
_mod_aaaa="${_mod_aaaa%%$'\n'*}"
if [[ -n "$_mod_aaaa" && "$_mod_aaaa" != "::" && "$_mod_aaaa" != "::1" ]]; then
  warn "Modem ${GATEWAY_IP} AAAA reklam kaciriyor (${_mod_aaaa})"
fi
unset _mod_a _mod_aaaa
echo ""
echo "=== Bilinen sinirlar ==="
echo "  YouTube / Instagram / TikTok feed: DNS ile engellenmez"
echo "  Cozum: uBlock (tarayici) + router DNS kilidi (ikincil DNS yok)"
echo "  Pi resolv .1 = AGH-down fallback (bootstrap); modem resolver reklam engellemez"
echo "  Ethernet+WiFi: kablolu NIC public DNS WAN :53 drop ile olur — Mac: make mac-dns"
echo "  Modem .1 INPUT :53: IP filtre FORWARD yetmez; istemci Pi-only (Mac: make mac-dns)"
echo "  ZTE H3600P: adguard-dhcp + relay LAN DISCOVER yutuyor — modem DHCP acik kalsin (docs/ADGUARD-DHCP.md)"
echo "  IPv6: radvd 3–4s modem LL AdvRDNSSLifetime 0; modem RA 900s last-RA"
echo ""
echo "Sonuc: ${ok} OK, ${fail_count} FAIL"
[[ "$fail_count" -eq 0 ]]
