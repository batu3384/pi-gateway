#!/usr/bin/env bash
# Reklam engelleme / DNS bypass teşhisi
set -euo pipefail

REMOTE_DIR="${REMOTE_DIR:-/home/${USER}/pi-gateway}"
# shellcheck source=/dev/null
[[ -f "$REMOTE_DIR/.env" ]] && source "$REMOTE_DIR/.env"
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=../lib/adguard-api.sh
source "$SCRIPT_DIR/../lib/adguard-api.sh"

PI_IP="${PI_STATIC_IP:-192.168.1.112}"
ADGUARD_WEB_PORT="${ADGUARD_WEB_PORT:-8080}"
AGH_ADMIN_USER="${AGH_ADMIN_USER:-admin}"
AGH_ADMIN_PASSWORD="${AGH_ADMIN_PASSWORD:-}"

ok=0 fail=0
pass() { echo "[OK] $*"; ok=$((ok + 1)); }
fail() { echo "[FAIL] $*"; fail=$((fail + 1)); }
warn() { echo "[WARN] $*"; }

echo "=== Reklam engelleme (DNS) teşhisi ==="
echo "NETWORK_MODE=${NETWORK_MODE:-router-dns}"

if dig +short @"${PI_IP}" doubleclick.net A 2>/dev/null | grep -qx '0.0.0.0'; then
  pass "Pi DNS doubleclick.net engelliyor"
else
  fail "Pi DNS doubleclick.net engellemiyor"
fi

if dig +short @8.8.8.8 doubleclick.net A 2>/dev/null | grep -qv '0.0.0.0'; then
  pass "Karsilastirma: Google DNS engellemiyor (beklenen)"
else
  warn "Google DNS de 0.0.0.0 dondu — garip"
fi

if [[ -n "$AGH_ADMIN_PASSWORD" ]]; then
  COOKIE="$(mktemp)"
  trap 'rm -f "$COOKIE"' EXIT
  if agh_login "http://127.0.0.1:${ADGUARD_WEB_PORT}" "$COOKIE" "$AGH_ADMIN_USER" "$AGH_ADMIN_PASSWORD" 2>/dev/null; then
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
    pass "${enabled} filtre listesi aktif"
  else
    fail "AdGuard API login"
  fi
fi

echo ""
echo "=== Cihazlar query log'da mi? (son 50) ==="
if [[ -n "${AGH_ADMIN_PASSWORD:-}" ]]; then
  curl -fsS -b "$COOKIE" "http://127.0.0.1:${ADGUARD_WEB_PORT}/control/querylog?older_than=&limit=50" 2>/dev/null | python3 -c "
import json,sys
from collections import Counter
c=Counter()
for x in json.load(sys.stdin).get('data',[]):
    ip=x.get('client','')
    if ip.startswith('192.168.'): c[ip]+=1
if not c:
    print('[WARN] LAN cihazi query logda yok — bypass olabilir')
else:
    for ip,n in c.most_common(8):
        print(f'  {ip}: {n} sorgu')
" || true
fi

echo ""
echo "=== Bilinen sinirlar ==="
echo "  YouTube / Instagram / TikTok feed: DNS ile engellenmez"
echo "  Cozum: uBlock (tarayici) + router DNS kilidi (ikincil DNS yok)"
echo ""
echo "Router kontrol: DHCP DNS1=${PI_IP}, DNS2=BOS"
echo "Sonuc: ${ok} OK, ${fail} FAIL"
