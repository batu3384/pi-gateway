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
grep -q 'python DISCOVER' "$PROJECT_DIR/scripts/lib/dhcp-dns-offer.sh" \
  || die "dhcp-dns python DISCOVER fallback yok"
grep -q 'adguard-dhcp OFFER hâlâ modem DNS' "$PROJECT_DIR/scripts/lib/dhcp-dns-offer.sh" \
  || die "dhcp-dns adguard-dhcp modem DNS FAIL yok"
grep -q 'pi-gateway dhcp' "$PROJECT_DIR/scripts/pi/setup-firewall.sh" \
  || die "UFW adguard-dhcp UDP/67 yok"
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
grep -q 'filter_53' "$PROJECT_DIR/config/adguard/filter-lists.json" \
  || die "AWAvenue filter_53 yok"
grep -q 'native.lgwebos' "$PROJECT_DIR/config/adguard/filter-lists.json" \
  || die "HaGeZi native.lgwebos yok"
grep -q 'adblock/tif.txt' "$PROJECT_DIR/config/adguard/filter-lists.json" \
  || die "HaGeZi TIF Full (tif.txt) aggressive profilde yok"
grep -q 'tif.full.txt' "$PROJECT_DIR/config/adguard/filter-lists.json" \
  && die "tif.full.txt yok (HaGeZi dosya adi tif.txt; jsDelivr 403)"
grep -q 'filter_7.txt' "$PROJECT_DIR/config/adguard/filter-lists.json" \
  || die "Smart TV HostlistsRegistry filter_7 yok"
grep -q 'iptables REDIRECT' "$PROJECT_DIR/docs/DNS-BLOCKING.md" \
  || die "DNS-BLOCKING Pi NAT anti-pattern yok"
grep -F 'ponytail: AGH add/remove_url' "$PROJECT_DIR/scripts/pi/apply-adguard-filters.sh" >/dev/null \
  || die "apply-adguard-filters AGH non-JSON POST govde"
grep -q 'AGH non-JSON' "$PROJECT_DIR/scripts/pi/apply-adguard-filters.sh" \
  || die "apply-adguard-filters HTML/hata govdeyi basari saymamali"
grep -q '8.8.8.8 UDP timeout' "$PROJECT_DIR/scripts/pi/diagnose-dns-bypass.sh" \
  || die "diagnose 8.8.8.8 timeout ≠ 0.0.0.0 WARN"
grep -q 'Filtre Kriterleri' "$PROJECT_DIR/docs/DNS-BLOCKING.md" \
  || die "DNS-BLOCKING H3600P IP filtresi yok"
grep -q 'panel DNS2 yok sayilir' "$PROJECT_DIR/scripts/lib/dhcp-dns-offer.sh" \
  || die "dhcp-dns ZTE panel DNS2 yok sayilir notu yok"
grep -q 'DoT forward' "$PROJECT_DIR/docs/ARCHITECTURE.md" \
  || die "ARCHITECTURE Unbound hâlâ recursive"
grep -q 'forward-tls-upstream: yes' "$PROJECT_DIR/config/unbound/unbound.conf" \
  || die "unbound DoT forward-tls-upstream yok"
grep -q '8.8.8.8 :53 acik' "$PROJECT_DIR/scripts/pi/diagnose-dns-bypass.sh" \
  || die "diagnose 8.8.8.8 acik dest-bos FAIL yok"
grep -q 'INPUT :53 (FORWARD filtre yetmez) / DHCP DNS2' "$PROJECT_DIR/scripts/pi/diagnose-dns-bypass.sh" \
  || die "diagnose modem LAN resolver leak yok"
grep -q 'dest bos kural eksik' "$PROJECT_DIR/scripts/pi/diagnose-dns-bypass.sh" \
  || die "diagnose 8.8.4.4 acik dest-bos FAIL yok"
awk '/^adguard-tune:/,/^recover-stack:/' "$PROJECT_DIR/Makefile" | grep -q 'force-recreate --no-deps unbound' \
  || die "adguard-tune unbound recreate yok"
grep -q 'AAAA' "$PROJECT_DIR/scripts/pi/diagnose-dns-bypass.sh" \
  || die "diagnose AAAA block yok"
grep -q 'adguard-block-aaaa' "$PROJECT_DIR/scripts/pi/health-check.sh" \
  || die "health AAAA block yok"
grep -q 'block-doubleclick-aaaa' "$PROJECT_DIR/scripts/mac/dns-test.sh" \
  || die "dns-test AAAA block yok"
grep -q '9.9.9.9@853' "$PROJECT_DIR/config/unbound/unbound.conf" \
  || die "unbound DoT Quad9 853 yok"
grep -qE '^[[:space:]]*port: 5335' "$PROJECT_DIR/config/unbound/unbound.conf" \
  || die "unbound.conf port 5335 yok (imaj default 53)"
grep -q '1.0.0.1 9.9.9.9' "$PROJECT_DIR/scripts/pi/diagnose-dns-bypass.sh" \
  || die "diagnose 1.0.0.1/9.9.9.9 WAN drop yok"
grep -q 'WAN drop' "$PROJECT_DIR/scripts/pi/diagnose-dns-bypass.sh" \
  || die "diagnose WAN drop mesaji yok"
grep -q 'dest boş' "$PROJECT_DIR/docs/DNS-BLOCKING.md" \
  || die "DNS-BLOCKING dest boş :53 yok"
grep -q 'force-recreate unbound' "$PROJECT_DIR/scripts/pi/canary-compose-update.sh" \
  || die "canary unbound recreate yok (DoT bind-mount)"
grep -q 'condition: service_started' "$PROJECT_DIR/compose/docker-compose.yml" \
  || die "adguard depends_on unbound service_started yok (WAN drop healthcheck)"
awk '/^  unbound:/,/^  adguard:/' "$PROJECT_DIR/compose/docker-compose.yml" | grep -q 'disable: true' \
  || die "unbound healthcheck disable yok (WAN drop recover dongusu)"
grep -A3 'FIX_LIGHT" == "true"' "$PROJECT_DIR/scripts/pi/ensure-adguard-blocking.sh" | grep -q heal_light \
  || die "ensure-adguard --fix-light diagnose-once heal yok"
grep -q 'unbound-dot-conf' "$PROJECT_DIR/scripts/pi/health-check.sh" \
  || die "health unbound-dot-conf yok"
grep -q 'unbound-stale-conf' "$PROJECT_DIR/scripts/pi/health-check.sh" \
  || die "health unbound-stale-conf yok"
grep -q 'host_label' "$PROJECT_DIR/scripts/pi/audit-dns-coverage.sh" \
  || die "audit NetAlertX cihaz adi yok"
grep -q '/control/clients' "$PROJECT_DIR/scripts/pi/audit-dns-coverage.sh" \
  || die "audit AGH client adi yok"
grep -q 'HATA set_rules' "$PROJECT_DIR/scripts/pi/apply-adguard-filters.sh" \
  || die "apply-adguard-filters set_rules try/except yok"
grep -q 'ROUTER_DNS_SECONDARY:-1.1.1.1' "$PROJECT_DIR/scripts/mac/setup-dns-fallback.sh" \
  && die "dns-fallback hala public 1.1.1.1 default"
grep -q 'is_public_dns' "$PROJECT_DIR/scripts/mac/setup-dns-fallback.sh" \
  || die "dns-fallback public DNS reddi yok"
grep -q 'mapfile' "$PROJECT_DIR/scripts/mac/setup-dns-fallback.sh" \
  && die "dns-fallback mapfile bash3 Mac'te yok"
grep -q 'setup-dns-fallback.sh' "$PROJECT_DIR/Makefile" \
  || die "Makefile mac-dns setup-dns-fallback yok"
grep -q 'MAC_DNS_GATEWAY_FALLBACK:-false' "$PROJECT_DIR/scripts/mac/setup-dns-fallback.sh" \
  || die "dns-fallback MAC_DNS_GATEWAY_FALLBACK default false yok"
grep -q 'ipv4_in_lan' "$PROJECT_DIR/scripts/mac/setup-dns-fallback.sh" \
  || die "dns-fallback LAN-only ipv4_in_lan yok"
grep -q 'load_env' "$PROJECT_DIR/scripts/mac/setup-local-dns.sh" \
  || die "setup-local-dns load_env yok (PROJECT_DIR bos = PI_STATIC_IP kaybolur)"
grep -q 'for scoped queries' "$PROJECT_DIR/scripts/mac/dns-test.sh" \
  || die "dns-test scoped resolver (Tailscale #1 gizler fe80) yok"
grep -q 'gw_re=' "$PROJECT_DIR/scripts/mac/dns-test.sh" \
  || die "dns-test LAN_GATEWAY prefix (192.168.1.1 ⊂ .112) yok"
grep -q 'grep -Fxq' "$PROJECT_DIR/scripts/mac/doctor.sh" \
  || die "doctor Ethernet DNS satir eslesmesi yok (1 ⊂ .112 false WARN)"
# mac-dns: once fallback (Ethernet Pi), sonra local-dns (gateway.home test)
awk '/^mac-dns:/{f=1;next} f && /^[^[:space:]#]/{exit} f' "$PROJECT_DIR/Makefile" \
  | grep -n 'setup-dns-fallback\|setup-local-dns' \
  | awk -F: 'BEGIN{ok=0} /fallback/{a=$1} /local-dns/{b=$1} END{exit !(a && b && a<b)}' \
  || die "Makefile mac-dns once fallback sonra local-dns degil"
grep -q 'mac-dns-clear' "$PROJECT_DIR/Makefile" \
  || die "Makefile mac-dns-clear yok"
grep -q 'H3600P' "$PROJECT_DIR/INSTALL.md" \
  || die "INSTALL ZTE H3600P DNS2/relay yok"
grep -q 'ZTE H3600P: adguard-dhcp' "$PROJECT_DIR/scripts/pi/diagnose-dns-bypass.sh" \
  || die "diagnose ZTE adguard-dhcp yasak uyarisi yok"
grep -q 'SO_BINDTODEVICE' "$PROJECT_DIR/scripts/lib/dhcp-dns-offer.sh" \
  || die "dhcp-dns python SO_BINDTODEVICE yok"
grep -E 'networksetup -setdnsservers.*"\$svc".*2>/dev/null' "$PROJECT_DIR/scripts/mac/setup-dns-fallback.sh" \
  && die "dns-fallback networksetup stderr yutuyor"
grep -q 'ZTE H3600P' "$PROJECT_DIR/README.md" \
  || die "README ZTE DNS2 yok"
grep -q 'wiki/_Sidebar.md' "$PROJECT_DIR/wiki/README.md" \
  || die "wiki README wiki/_Sidebar.md backtick yok"
grep -q 'py relative import yok' "$PROJECT_DIR/docs/SCRIPTS.md" \
  || die "SCRIPTS.md py CLI notu yok"
grep -q 'MAC_DNS_GATEWAY_FALLBACK' "$PROJECT_DIR/.env.example" \
  || die ".env.example MAC_DNS_GATEWAY_FALLBACK yok"
grep -q 'MAC_DNS_GATEWAY_FALLBACK' "$PROJECT_DIR/scripts/mac/doctor.sh" \
  || die "doctor MAC_DNS_GATEWAY_FALLBACK warn yok"
grep -q 'ensure-ipv6-ula' "$PROJECT_DIR/Makefile" \
  || die "Makefile ensure-ipv6-ula yok"
grep -q 'setup-rdnss-ra' "$PROJECT_DIR/Makefile" \
  || die "Makefile setup-rdnss-ra yok"
grep -q 'PI_IPV6_ULA' "$PROJECT_DIR/.env.example" \
  || die ".env.example PI_IPV6_ULA yok"
grep -q 'AdvRDNSSLifetime 0' "$PROJECT_DIR/scripts/pi/setup-rdnss-ra.sh" \
  || die "rdnss RFC 8106 modem lifetime 0 yok"
grep -q 'MaxRtrAdvInterval 4' "$PROJECT_DIR/scripts/pi/setup-rdnss-ra.sh" \
  || die "rdnss MaxRtrAdvInterval 4 yok"
grep -q 'DHCP_RANGE_START' "$PROJECT_DIR/.env.example" \
  || die ".env.example DHCP_RANGE_START yok"
grep -Fq 'does **not** stop the resolver' "$PROJECT_DIR/README.md" \
  || die "README LAN IP filtre INPUT yetmez notu yok"

ok "dosyalar + sniff/rollout/audit/filtre/DoH/ULA/RDNSS kontratlari"
echo "[test-dns-blocking] Tum kontroller gecti"
