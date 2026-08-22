#!/usr/bin/env bash
# DNS blocking stack contracts (audit/diagnose/dhcp-sniff/rollout/filters)
set -euo pipefail
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROJECT_DIR="$(cd "$SCRIPT_DIR/../.." && pwd)"
die() { echo "[test-dns-blocking] HATA: $*" >&2; exit 1; }
ok() { echo "[test-dns-blocking] OK: $*"; }

need() { [[ -f "$1" ]] || die "eksik: $1"; }

need "$PROJECT_DIR/scripts/lib/dhcp-dns-offer.sh"
need "$PROJECT_DIR/scripts/pi/audit-dns-coverage.sh"
need "$PROJECT_DIR/scripts/pi/diagnose-dns-bypass.sh"
need "$PROJECT_DIR/scripts/pi/ensure-adguard-blocking.sh"
need "$PROJECT_DIR/scripts/pi/wait-dns-rollout.sh"
need "$PROJECT_DIR/scripts/pi/apply-adguard-filters.sh"
need "$PROJECT_DIR/config/adguard/filter-lists.json"
need "$PROJECT_DIR/config/adguard/user-rules.txt"
need "$PROJECT_DIR/host/systemd/pi-gateway-adguard-filters.timer"

grep -q 'check_dhcp_dns_offer' "$PROJECT_DIR/scripts/lib/dhcp-dns-offer.sh" \
  || die "check_dhcp_dns_offer yok"
grep -q 'timeout\|gtimeout' "$PROJECT_DIR/scripts/lib/dhcp-dns-offer.sh" \
  || die "dhcp sniff timeout yok"
grep -q 'MISSING_DEVICES' "$PROJECT_DIR/scripts/pi/wait-dns-rollout.sh" \
  || die "rollout MISSING_DEVICES parse yok"
grep -q 'set +e' "$PROJECT_DIR/scripts/pi/wait-dns-rollout.sh" \
  || die "rollout audit rc yakalama yok"
grep -q 'dhcp-dns-offer.sh' "$PROJECT_DIR/scripts/pi/diagnose-dns-bypass.sh" \
  || die "diagnose dhcp sniff bagli degil"
grep -q 'REACHABLE/DELAY\|online_ips' "$PROJECT_DIR/scripts/pi/audit-dns-coverage.sh" \
  || die "audit ARP state ayrimi yok"
grep -q 'balanced' "$PROJECT_DIR/config/adguard/filter-lists.json" \
  || die "filter-lists balanced profil yok"
grep -q 'aggressive' "$PROJECT_DIR/config/adguard/filter-lists.json" \
  || die "filter-lists aggressive profil yok"
grep -q 'adguard-tune' "$PROJECT_DIR/Makefile" \
  || die "Makefile adguard-tune yok"
grep -q 'rollout-dns-wait\|wait-dns-rollout' "$PROJECT_DIR/Makefile" \
  || die "Makefile rollout-dns-wait yok"
grep -q 'dhcp-dns-offer.sh' "$PROJECT_DIR/Makefile" \
  || die "adguard-tune lib sync yok"

grep -q 'doh.txt' "$PROJECT_DIR/config/adguard/filter-lists.json" \
  || die "HaGeZi DoH listesi filter-lists.json yok"
grep -q 'ensure-ipv6-ula' "$PROJECT_DIR/Makefile" \
  || die "Makefile ensure-ipv6-ula yok"
grep -q 'setup-rdnss-ra' "$PROJECT_DIR/Makefile" \
  || die "Makefile setup-rdnss-ra yok"
grep -q 'PI_IPV6_ULA' "$PROJECT_DIR/.env.example" \
  || die ".env.example PI_IPV6_ULA yok"
need "$PROJECT_DIR/scripts/pi/ensure-ipv6-ula.sh"
need "$PROJECT_DIR/scripts/pi/setup-rdnss-ra.sh"
need "$PROJECT_DIR/host/systemd/pi-gateway-ipv6-ula.service"

ok "dosyalar + sniff/rollout/audit/filtre/DoH/ULA/RDNSS kontratlari"
echo "[test-dns-blocking] Tum kontroller gecti"
