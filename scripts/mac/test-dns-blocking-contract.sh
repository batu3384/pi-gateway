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
need "$PROJECT_DIR/scripts/pi/apply-adguard-dns.sh"
need "$PROJECT_DIR/scripts/pi/apply-adguard-filters.sh"
need "$PROJECT_DIR/scripts/lib/adguard-filters.py"
need "$PROJECT_DIR/scripts/lib/modem_inventory.py"
need "$PROJECT_DIR/scripts/lib/zte-h3600p.py"
need "$PROJECT_DIR/scripts/pi/audit-modem-performance.sh"
need "$PROJECT_DIR/scripts/pi/sync-modem-inventory.sh"
need "$PROJECT_DIR/scripts/pi/observe-rdnss-ra.sh"
need "$PROJECT_DIR/scripts/pi/diagnose-video-path.sh"
need "$PROJECT_DIR/config/adguard/filter-lists.json"
need "$PROJECT_DIR/config/adguard/user-rules.txt"
need "$PROJECT_DIR/host/systemd/pi-gateway-adguard-filters.timer"
need "$PROJECT_DIR/host/systemd/pi-gateway-adguard-filters-failure.service"
need "$PROJECT_DIR/host/systemd/pi-gateway-modem-inventory.service"
need "$PROJECT_DIR/host/systemd/pi-gateway-modem-inventory.timer"

grep -q 'check_dhcp_dns_offer' "$PROJECT_DIR/scripts/lib/dhcp-dns-offer.sh" \
  || die "check_dhcp_dns_offer yok"
bash "$PROJECT_DIR/scripts/pi/audit-modem-performance.sh" --self-check \
  || die "modem performance audit self-check"
! grep -q 'MODEM_ALLOW_HTTP=true' "$PROJECT_DIR/scripts/pi/audit-modem-performance.sh" \
  || die "modem audit HTTP opt-in bypass"
grep -q 'MODEM_ALLOW_HTTP' "$PROJECT_DIR/scripts/pi/sync-modem-inventory.sh" \
  || die "modem HTTP policy yok"
grep -q 'python DISCOVER' "$PROJECT_DIR/scripts/lib/dhcp-dns-offer.sh" \
  || die "dhcp-dns python DISCOVER fallback yok"
grep -q 'bilinmeyen DNS bypass' "$PROJECT_DIR/scripts/lib/dhcp-dns-offer.sh" \
  || die "dhcp-dns unknown resolver guard yok"
grep -q 'degraded=3' "$PROJECT_DIR/scripts/lib/dhcp-dns-offer.sh" \
  || die "dhcp-dns modem fallback degraded sonucu yok"
grep -q 'adguard-dhcp OFFER hâlâ modem DNS' "$PROJECT_DIR/scripts/lib/dhcp-dns-offer.sh" \
  || die "dhcp-dns adguard-dhcp modem DNS FAIL yok"
grep -q 'pi-gateway dhcp' "$PROJECT_DIR/scripts/pi/setup-firewall.sh" \
  || die "UFW adguard-dhcp UDP/67 yok"
grep -q 'in on tailscale0 to any port 53 proto udp' "$PROJECT_DIR/scripts/pi/setup-firewall.sh" \
  || die "UFW tailscale0 :53/udp yok (global NS)"
grep -q 'in on tailscale0 to any port 53 proto tcp' "$PROJECT_DIR/scripts/pi/setup-firewall.sh" \
  || die "UFW tailscale0 :53/tcp yok"
grep -q 'TS_PANEL_DIRECT_PORTS' "$PROJECT_DIR/scripts/pi/setup-firewall.sh" \
  || die "UFW TS_PANEL portlari yok"
if grep -q 'for port in 22 80 443 53' "$PROJECT_DIR/scripts/pi/setup-firewall.sh"; then
  die "UFW :53 TCP dongusunde — UDP ayri sart"
fi
grep -q -- '--accept-dns=false' "$PROJECT_DIR/scripts/pi/setup-tailscale-remote.sh" \
  || die "tailscale-remote accept-dns=false yok"
grep -q 'overrideLocalDNS' "$PROJECT_DIR/scripts/pi/setup-tailscale-dns.sh" \
  || die "setup-tailscale-dns overrideLocalDNS yok"
grep -q 'tskey-api-' "$PROJECT_DIR/scripts/pi/setup-tailscale-dns.sh" \
  || die "setup-tailscale-dns API key gate yok"
grep -q 'setup-tailscale-dns.sh' "$PROJECT_DIR/scripts/pi/post-deploy.sh" \
  || die "post-deploy Tailscale DNS yok"
grep -q 'Uzak kanit' "$PROJECT_DIR/scripts/pi/diagnose-remote-access.sh" \
  || die "diagnose uzak kanit (Mac dig @100.x) yok"
grep -q 'pi-gateway tailscale-53' "$PROJECT_DIR/scripts/pi/diagnose-remote-access.sh" \
  || die "diagnose UFW tailscale-53 yok"
grep -q 'MISSING_DEVICES' "$PROJECT_DIR/scripts/pi/wait-dns-rollout.sh" \
  || die "rollout MISSING_DEVICES parse yok"
grep -q 'set +e' "$PROJECT_DIR/scripts/pi/wait-dns-rollout.sh" \
  || die "rollout audit rc yakalama yok"
grep -q 'dhcp-dns-offer.sh' "$PROJECT_DIR/scripts/pi/diagnose-dns-bypass.sh" \
  || die "diagnose dhcp sniff bagli degil"
grep -q 'observe-rdnss-ra.sh' "$PROJECT_DIR/scripts/pi/diagnose-dns-bypass.sh" \
  || die "diagnose gercek RA/RDNSS gozlemi yok"
grep -q 'exit 2' "$PROJECT_DIR/scripts/pi/observe-rdnss-ra.sh" \
  || die "rdnss gozlem belirsiz durumda fail-open"
grep -q 'lifetime' "$PROJECT_DIR/scripts/pi/observe-rdnss-ra.sh" \
  || die "rdnss lifetime semantigi yok"
grep -q 'VIDEO_QUERY_RECENCY_SEC' "$PROJECT_DIR/scripts/pi/diagnose-video-path.sh" \
  || die "video query recency yok"
grep -q 'inventory.get("fresh")' "$PROJECT_DIR/scripts/pi/diagnose-video-path.sh" \
  || die "video stale inventory gate yok"
grep -q 'ipaddress.ip_address' "$PROJECT_DIR/scripts/pi/diagnose-video-path.sh" \
  || die "video hedef IP validation yok"
grep -q 'VIDEO_CLIENT_MAX_LOSS_PERCENT' "$PROJECT_DIR/scripts/pi/diagnose-video-path.sh" \
  || die "video client loss esigi yok"
grep -q 'VIDEO_CLIENT_MAX_JITTER_MS' "$PROJECT_DIR/scripts/pi/diagnose-video-path.sh" \
  || die "video client jitter esigi yok"
grep -q 'VIDEO_PROBE_STATUS=FAIL' "$PROJECT_DIR/scripts/pi/diagnose-video-path.sh" \
  || die "video fail status yok"
grep -q 'exit 10' "$PROJECT_DIR/scripts/pi/diagnose-video-path.sh" \
  || die "video WARN exit code yok"
grep -q 'VIDEO_HTTP_PROBE' "$PROJECT_DIR/scripts/pi/diagnose-video-path.sh" \
  || die "video HTTPS WAN probe yok"
grep -q 'Geçiş öncesi repo kapıları' "$PROJECT_DIR/docs/OPENWRT-DNS-ENFORCEMENT.md" \
  || die "OpenWrt gecis oncesi repo kapilari yok"
grep -q 'LAN -> TCP/UDP 853 WAN   REJECT' "$PROJECT_DIR/docs/OPENWRT-DNS-ENFORCEMENT.md" \
  || die "OpenWrt 853 reject kapisi yok"
grep -q 'REACHABLE/DELAY\|online_ips' "$PROJECT_DIR/scripts/pi/audit-dns-coverage.sh" \
  || die "audit ARP state ayrimi yok"
grep -q 'ADGUARD_AUDIT_QUERY_RECENCY_SEC' "$PROJECT_DIR/scripts/pi/audit-dns-coverage.sh" \
  || die "audit query recency ayari yok"
grep -q 'query_is_recent' "$PROJECT_DIR/scripts/pi/audit-dns-coverage.sh" \
  || die "audit eski query logu aktif sayiyor"
grep -q 'USING_PI_DNS\|POSSIBLE_BYPASS\|STALE\|UNKNOWN' "$PROJECT_DIR/scripts/pi/audit-dns-coverage.sh" \
  || die "audit durum siniflari yok"
grep -q 'MODEM_INVENTORY_ENABLED\|MODEM_INVENTORY_STALE_SEC\|MODEM_INVENTORY_REQUIRED' "$PROJECT_DIR/scripts/pi/audit-dns-coverage.sh" \
  || die "audit modem snapshot stale/required politikasi yok"
grep -q 'inventory_unknown = modem_required and not modem\["fresh"\]' "$PROJECT_DIR/scripts/pi/audit-dns-coverage.sh" \
  || die "audit disabled inventory stale gate bozuk"
grep -q 'ADGUARD_COVERAGE_AUDIT_MODE' "$PROJECT_DIR/scripts/pi/audit-dns-coverage.sh" \
  || die "audit health warn modu yok"
grep -q 'write_state' "$PROJECT_DIR/scripts/pi/audit-dns-coverage.sh" \
  || die "audit coverage state persistence yok"
grep -q 'dns_coverage_state_age_seconds' "$PROJECT_DIR/scripts/pi/export-gateway-state.sh" \
  || die "export coverage evidence age metric yok"
grep -q 'dns_coverage_protocol_unknown' "$PROJECT_DIR/scripts/pi/export-gateway-state.sh" \
  || die "export protocol unknown metric yok"
grep -q 'ipv6_rdnss_configured' "$PROJECT_DIR/scripts/pi/export-gateway-state.sh" \
  || die "export IPv6 RDNSS config metric yok"
grep -q 'ADGUARD_COVERAGE_AUDIT_ENABLED' "$PROJECT_DIR/scripts/pi/health-check.sh" \
  || die "health coverage audit toggle yok"
grep -q 'DNS kapsam auditi PASS degil' "$PROJECT_DIR/scripts/pi/diagnose-dns-bypass.sh" \
  || die "diagnose coverage WARN evidence yok"
grep -q 'coverage_state_status' "$PROJECT_DIR/scripts/pi/audit-dns-coverage.sh" \
  || die "audit coverage status evidence yok"
grep -q 'DNS coverage evidence' "$PROJECT_DIR/config/grafana/provisioning/dashboards/json/pi-gateway.json" \
  || die "Grafana DNS coverage panel yok"
grep -q 'DNS rollout' "$PROJECT_DIR/docs/OPERATIONS.md" \
  || die "DNS rollout runbook yok"
grep -q 'LoadCredential=modem' "$PROJECT_DIR/host/systemd/pi-gateway-modem-inventory.service" \
  || die "modem credential systemd LoadCredential yok"
grep -q 'Environment=REMOTE_DIR=' "$PROJECT_DIR/host/systemd/pi-gateway-modem-inventory.service" \
  || die "modem inventory service REMOTE_DIR yok"
grep -q 'OnUnitActiveSec=5min' "$PROJECT_DIR/host/systemd/pi-gateway-modem-inventory.timer" \
  || die "modem inventory periyodik timer yok"
grep -q 'OnFailure=pi-gateway-adguard-filters-failure.service' \
  "$PROJECT_DIR/host/systemd/pi-gateway-adguard-filters.service" \
  || die "adguard filter OnFailure alert yok"
grep -q 'FAILURE_KIND=adguard-filter' \
  "$PROJECT_DIR/host/systemd/pi-gateway-adguard-filters-failure.service" \
  || die "adguard filter failure kind yok"
grep -q 'pi-gateway-modem-inventory.timer' "$PROJECT_DIR/scripts/pi/setup-home-ops-timers.sh" \
  || die "modem inventory timer kuruluma bagli degil"
grep -q 'must_not_block_hosts\|max_age_hours\|min_rules' "$PROJECT_DIR/config/adguard/filter-lists.json" \
  || die "filter governance metadata/regression yok"
grep -q '"budgets"' "$PROJECT_DIR/config/adguard/filter-lists.json" \
  || die "filter total rule budget yok"
python3 -m json.tool "$PROJECT_DIR/config/adguard/filter-lists.json" >/dev/null \
  || die "filter-lists.json gecersiz JSON"
python3 "$PROJECT_DIR/scripts/lib/zte-h3600p.py" --self-check \
  || die "zte-h3600p self-check"
python3 "$PROJECT_DIR/scripts/lib/modem_inventory.py" --self-check \
  || die "modem_inventory self-check"
python3 "$PROJECT_DIR/scripts/lib/netalert-devices.py" --self-check \
  || die "netalert-devices modem isim self-check"
grep -q 'balanced-core' "$PROJECT_DIR/config/adguard/filter-lists.json" \
  || die "filter-lists balanced-core profil yok"
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
grep -q 'ADGUARD_RATELIMIT' "$PROJECT_DIR/scripts/pi/apply-adguard-dns.sh" \
  || die "apply-adguard-dns RATELIMIT yok"
grep -q 'querylog_config' "$PROJECT_DIR/scripts/pi/apply-adguard-dns.sh" \
  || die "apply-adguard-dns querylog_config yok"
grep -q 'ADGUARD_RATELIMIT=50' "$PROJECT_DIR/.env.example" \
  || die ".env.example ADGUARD_RATELIMIT yok"
grep -q 'ratelimit: 50' "$PROJECT_DIR/config/adguard/AdGuardHome.yaml.template" \
  || die "AGH template ratelimit 50 yok"
grep -q 'interval: 168h' "$PROJECT_DIR/config/adguard/AdGuardHome.yaml.template" \
  || die "AGH template querylog 168h yok"
grep -q 'ADGUARD_RATELIMIT=50' "$PROJECT_DIR/docs/DNS-BLOCKING.md" \
  || die "DNS-BLOCKING knobs dokuman yok"
awk '/^adguard-tune:/,/^recover-stack:/' "$PROJECT_DIR/Makefile" | grep -q 'apply-adguard-dns.sh' \
  || die "Makefile adguard-tune apply-adguard-dns sync yok"
awk '/^adguard-tune:/,/^recover-stack:/' "$PROJECT_DIR/Makefile" | grep -q 'adguard-filters.py' \
  || die "Makefile adguard-tune adguard-filters.py sync yok"
grep -q 'flock -w' "$PROJECT_DIR/scripts/pi/apply-adguard-filters.sh" \
  || die "apply-adguard-filters flock yok"
grep -q 'IN_PROGRESS_FILE' "$PROJECT_DIR/scripts/pi/apply-adguard-filters.sh" \
  || die "apply-adguard-filters in_progress flag yok"
grep -q 'filtering_api_ready' "$PROJECT_DIR/scripts/pi/apply-adguard-filters.sh" \
  || die "apply-adguard-filters filtering API readiness yok"
grep -q 'AguardApiError' "$PROJECT_DIR/scripts/lib/adguard-filters.py" \
  || die "adguard-filters API hata guard yok"
grep -q 'first in ("ok", "true")' "$PROJECT_DIR/scripts/lib/adguard-filters.py" \
  || die "adguard-filters OK prefix guard yok"
grep -q 'set_rules' "$PROJECT_DIR/scripts/lib/adguard-filters.py" \
  || die "adguard-filters set_rules yok"
grep -q 'cache_clear' "$PROJECT_DIR/scripts/lib/adguard-filters.py" \
  || die "adguard-filters cache_clear yok"
grep -q 'agh_match' "$PROJECT_DIR/scripts/lib/adguard-filters.py" \
  || die "adguard-filters AGH user_rules kiyas yok"
grep -q 'set_url' "$PROJECT_DIR/scripts/lib/adguard-filters.py" \
  || die "adguard-filters disabled liste enable (set_url) yok"
grep -q 'remove_stale_lists' "$PROJECT_DIR/scripts/lib/adguard-filters.py" \
  || die "adguard-filters stale remove governance sonrasi yok"
grep -q 'reconcile oncesi stale kaldirildi' "$PROJECT_DIR/scripts/lib/adguard-filters.py" \
  || die "adguard-filters pre-reconcile stale remove yok"
grep -q 'repair-prometheus-tsdb.sh' "$PROJECT_DIR/scripts/pi/health-check.sh" \
  || die "health-check prometheus TSDB auto-heal yok"
grep -q 'pi-gateway-container-watchdog.timer' "$PROJECT_DIR/scripts/pi/setup-home-ops-timers.sh" \
  || die "home-ops container-watchdog timer yok"
grep -q 'notify_monitoring_stack_warn' "$PROJECT_DIR/scripts/lib/notify.sh" \
  || die "notify monitoring-stack yok"
grep -q 'notify_prometheus_repair' "$PROJECT_DIR/scripts/lib/notify.sh" \
  || die "notify prometheus-repair yok"
grep -q 'check_live_regressions' "$PROJECT_DIR/scripts/lib/adguard-filters.py" \
  || die "adguard-filters live regression set_rules sonrasi yok"
grep -q 'If-Modified-Since' "$PROJECT_DIR/scripts/lib/adguard-filters.py" \
  || die "adguard-filters ETag/IMS source cache yok"
grep -q 'last_good_sha256_sample' "$PROJECT_DIR/scripts/lib/adguard-filters.py" \
  || die "adguard-filters last-known-good sample yok"
grep -q 'last_good_sha256' "$PROJECT_DIR/scripts/lib/adguard-filters.py" \
  || die "adguard-filters full source hash yok"
grep -q 'rollback_failed' "$PROJECT_DIR/scripts/lib/adguard-filters.py" \
  || die "adguard-filters rollback failure state yok"
grep -q 'refresh_verified' "$PROJECT_DIR/scripts/lib/adguard-filters.py" \
  || die "adguard-filters refresh verification yok"
grep -q 'profil kural butcesi asildi' "$PROJECT_DIR/scripts/lib/adguard-filters.py" \
  || die "adguard-filters total rule budget guard yok"
python3 "$PROJECT_DIR/scripts/lib/adguard-filters.py" --self-check \
  || die "adguard-filters self-check"
grep -q 'ponytail: TIF Full' "$PROJECT_DIR/scripts/pi/apply-adguard-filters.sh" \
  || die "apply-adguard-filters TIF Full MemAvailable tavan yok"
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
awk '/^adguard-tune:/,/^recover-stack:/' "$PROJECT_DIR/Makefile" | grep -q 'adguard-tune.sh' \
  || die "Makefile adguard-tune.sh cagirmiyor"
[[ -f "$PROJECT_DIR/scripts/pi/adguard-tune.sh" ]] || die "adguard-tune.sh yok"
grep -q 'force-recreate --no-deps unbound' "$PROJECT_DIR/scripts/pi/adguard-tune.sh" \
  || die "adguard-tune unbound recreate yok"
grep -q 'Unbound conf taze' "$PROJECT_DIR/scripts/pi/adguard-tune.sh" \
  || die "adguard-tune stale degilse recreate atlamıyor"
grep -q 'unbound_conf_stale' "$PROJECT_DIR/scripts/lib/stack-health.sh" \
  || die "stack-health unbound_conf_stale yok"
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
! grep -A8 '^heal_light()' "$PROJECT_DIR/scripts/pi/ensure-adguard-blocking.sh" | grep -q 'apply-adguard-filters.sh' \
  || die "heal_light filter apply cache_clear yapiyor"
grep -q 'GATEWAY_VIDEO_DNS_PROBE' "$PROJECT_DIR/scripts/lib/gateway-probes.py" \
  || die "gateway probes video DNS toggle yok"
grep -q 'ADGUARD_COVERAGE_AUDIT_ENABLED:-false' "$PROJECT_DIR/scripts/pi/health-check.sh" \
  || die "health coverage audit default acik"
grep -q 'unbound-dot-conf' "$PROJECT_DIR/scripts/pi/health-check.sh" \
  || die "health unbound-dot-conf yok"
grep -q 'unbound-stale-conf' "$PROJECT_DIR/scripts/pi/health-check.sh" \
  || die "health unbound-stale-conf yok"
grep -q 'host_label' "$PROJECT_DIR/scripts/pi/audit-dns-coverage.sh" \
  || die "audit NetAlertX cihaz adi yok"
grep -q '/control/clients' "$PROJECT_DIR/scripts/pi/audit-dns-coverage.sh" \
  || die "audit AGH client adi yok"
grep -q 'modem_inventory import' "$PROJECT_DIR/scripts/pi/diagnose-video-path.sh" \
  || die "video diagnose shared modem inventory loader yok"
grep -q 'probe_ping client.*20' "$PROJECT_DIR/scripts/pi/diagnose-video-path.sh" \
  || die "video diagnose cihaz RTT/packet loss yok"
grep -q 'VIDEO_NEIGH label=client' "$PROJECT_DIR/scripts/pi/diagnose-video-path.sh" \
  || die "video diagnose ARP/neigh ICMP filtresi yok"
grep -q 'icmp-filtered' "$PROJECT_DIR/scripts/pi/diagnose-video-path.sh" \
  || die "video diagnose icmp-filtered notu yok"
grep -q 'Zaman=' "$PROJECT_DIR/scripts/pi/diagnose-video-path.sh" \
  || die "video diagnose zaman damgasi yok"
grep -q 'log_err(f"set_rules:' "$PROJECT_DIR/scripts/lib/adguard-filters.py" \
  || die "adguard-filters set_rules try/except yok"
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
grep -q 'ula_reachable' "$PROJECT_DIR/scripts/mac/setup-dns-fallback.sh" \
  || die "dns-fallback ULA erisilebilirlik probu yok"
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
grep -q 'AdvOnLink on' "$PROJECT_DIR/scripts/pi/setup-rdnss-ra.sh" \
  || die "rdnss ULA on-link prefix yok"
grep -q 'mac-ula-dns' "$PROJECT_DIR/scripts/mac/dns-test.sh" \
  || die "dns-test mac ULA erisilebilirlik kontrolu yok"
grep -q 'DHCP_RANGE_START' "$PROJECT_DIR/.env.example" \
  || die ".env.example DHCP_RANGE_START yok"
grep -Fq 'does **not** stop the resolver' "$PROJECT_DIR/README.md" \
  || die "README LAN IP filtre INPUT yetmez notu yok"
grep -q 'global nameserver = Pi Tailscale IPv4' "$PROJECT_DIR/docs/DNS-BLOCKING.md" \
  || die "DNS-BLOCKING Tailscale global NS yok"
grep -q 'Global nameserver' "$PROJECT_DIR/docs/TAILSCALE.md" \
  || die "TAILSCALE.md Global nameserver yok"
grep -q 'dig @100.x' "$PROJECT_DIR/docs/TAILSCALE.md" \
  || die "TAILSCALE.md uzak dig @100.x yok"

grep -q 'adblock/fake.txt' "$PROJECT_DIR/config/adguard/filter-lists.json" \
  && die "HaGeZi Fake Pro++ icinde — stack etme"
grep -q 'filter_59.txt' "$PROJECT_DIR/config/adguard/filter-lists.json" \
  && die "Popup Hosts Pro++ icinde — stack etme"
grep -q '||videooplayer.xyz^$important' "$PROJECT_DIR/config/adguard/user-rules.txt" \
  && die "user-rules videooplayer sniper geri geldi (player CDN kirar)"
grep -q '@@||entitlements.jwplayer.com^$important' "$PROJECT_DIR/config/adguard/user-rules.txt" \
  || die "user-rules JW entitlements allowlist yok"
grep -q '@@||jwpltx.com^$important' "$PROJECT_DIR/config/adguard/user-rules.txt" \
  || die "user-rules JW jwpltx allowlist yok"
grep -q '@@||dit.whatsapp.net^' "$PROJECT_DIR/config/adguard/user-rules.txt" \
  || die "user-rules WhatsApp allowlist yok"
grep -q '@@||graph-fallback.instagram.com^' "$PROJECT_DIR/config/adguard/user-rules.txt" \
  || die "user-rules Instagram graph-fallback allowlist yok"
grep -q '@@||mdp-appconf-tr.heytapdl.com^' "$PROJECT_DIR/config/adguard/user-rules.txt" \
  || die "user-rules Heytap appconf allowlist yok"
grep -q '@@||cloudconf-app-tr.heytapmobile.com^' "$PROJECT_DIR/config/adguard/user-rules.txt" \
  || die "user-rules Heytap cloudconf allowlist yok"
grep -q 'use-application-dns.net' "$PROJECT_DIR/config/adguard/user-rules.txt" \
  || die "user-rules DoH canary yok"
grep -q 'use-application-dns.net' "$PROJECT_DIR/config/adguard/filter-lists.json" \
  || die "filter-lists DoH canary regression yok"
need "$PROJECT_DIR/scripts/pi/suggest-dns-sniper.sh"
grep -q 'suggest-ad-sniper' "$PROJECT_DIR/Makefile" \
  || die "Makefile suggest-ad-sniper yok"
grep -q 'Browser DoH canary' "$PROJECT_DIR/scripts/pi/diagnose-dns-bypass.sh" \
  || die "diagnose-dns DoH canary testi yok"
grep -q 'DoT bypass' "$PROJECT_DIR/scripts/pi/diagnose-dns-bypass.sh" \
  || die "diagnose-dns DoT bolumu yok"
grep -q 'dest port.*853' "$PROJECT_DIR/docs/DNS-BLOCKING.md" \
  || die "DNS-BLOCKING DoT 853 modem notu yok"
grep -q 'adguard-filter-governance' "$PROJECT_DIR/scripts/pi/health-check.sh" \
  || die "health-check adguard-filter-governance yok"
grep -q 'governance-check' "$PROJECT_DIR/scripts/pi/health-check.sh" \
  || die "health-check adguard-filters --governance-check yok"
grep -q 'filter apply suruyor' "$PROJECT_DIR/scripts/pi/health-check.sh" \
  || die "health-check in_progress auto-heal skip yok"
grep -q 'modem_inventory import' "$PROJECT_DIR/scripts/pi/audit-dns-coverage.sh" \
  || die "audit shared modem inventory loader yok"
grep -q 'privacy_mac=true' "$PROJECT_DIR/scripts/pi/audit-dns-coverage.sh" \
  || die "audit privacy MAC metadata yok"
grep -q "last_seen=.*record" "$PROJECT_DIR/scripts/pi/audit-dns-coverage.sh" \
  || die "audit modem last_seen metadata yok"
grep -q 'stale haric' "$PROJECT_DIR/scripts/pi/audit-dns-coverage.sh" \
  || die "audit coverage stale cihazlari ayirmiyor"
grep -q 'crit "AdGuard filters"' "$PROJECT_DIR/scripts/pi/post-deploy-code.sh" \
  || die "post-deploy-code AdGuard filters soft degil crit olmali"
grep -q 'adguard-filters.py' "$PROJECT_DIR/scripts/pi/install-privileged-scripts.sh" \
  || die "install-privileged adguard-filters.py yok"
grep -q 'modem_inventory.py' "$PROJECT_DIR/scripts/pi/install-privileged-scripts.sh" \
  || die "install-privileged modem_inventory.py yok"
grep -q 'inventory_confidence' "$PROJECT_DIR/scripts/lib/netalert-devices.py" \
  || die "NetAlert inventory confidence yok"
grep -q 'inventory_last_seen' "$PROJECT_DIR/scripts/lib/netalert-devices.py" \
  || die "NetAlert inventory last_seen yok"
grep -q 'modem_inventory.py' "$PROJECT_DIR/Makefile" \
  || die "Makefile modem inventory shared loader sync yok"
grep -q 'ADGUARD_FILTER_POLL_SEC' "$PROJECT_DIR/.env.example" \
  || die ".env.example ADGUARD_FILTER_POLL_SEC yok"
grep -q 'ADGUARD_FILTER_LOCK_WAIT_SEC' "$PROJECT_DIR/.env.example" \
  || die ".env.example ADGUARD_FILTER_LOCK_WAIT_SEC yok"
grep -q 'ADGUARD_FILTER_SCHEDULED_SLA_SEC' "$PROJECT_DIR/.env.example" \
  || die ".env.example filter scheduled SLA yok"
grep -q 'VIDEO_QUERY_RECENCY_SEC' "$PROJECT_DIR/.env.example" \
  || die ".env.example video query recency yok"
grep -q 'VIDEO_HTTP_PROBE_URL' "$PROJECT_DIR/.env.example" \
  || die ".env.example video HTTPS probe yok"
grep -q 'VIDEO_CLIENT_MAX_JITTER_MS' "$PROJECT_DIR/.env.example" \
  || die ".env.example video jitter probe yok"
grep -q 'netalert_db_readable' "$PROJECT_DIR/scripts/lib/gateway-probes.py" \
  || die "gateway probes NetAlert readability yok"
grep -q 'pi_gateway_video_dns_latency_ms' "$PROJECT_DIR/scripts/lib/gateway-probes.py" \
  || die "gateway probes video DNS metric yok"
grep -Fq 'PGID: ${NETALERTX_GID:-1000}' "$PROJECT_DIR/compose/docker-compose.yml" \
  || die "NetAlertX host GID default yok"
grep -q '_pi_home_script apply-adguard-filters.sh' "$PROJECT_DIR/scripts/pi/health-check.sh" \
  || die "health-check apply-adguard-filters home SSOT yok"
grep -q '_pi_home_script ensure-adguard-blocking.sh' "$PROJECT_DIR/scripts/pi/health-check.sh" \
  || die "health-check ensure-adguard home SSOT yok"
grep -q '_pi_home_script apply-adguard-dns.sh' "$PROJECT_DIR/scripts/pi/health-check.sh" \
  || die "health-check apply-adguard-dns home SSOT yok"
grep -q 'ADGUARD_DNS_AUTO_HEAL' "$PROJECT_DIR/scripts/pi/health-check.sh" \
  || die "health-check ADGUARD_DNS_AUTO_HEAL yok"
grep -q 'rm -f /run/pi-gateway/health-last-exit.txt' "$PROJECT_DIR/scripts/pi/health-check.sh" \
  || die "health-check success health-last-exit temizligi yok"
grep -q 'notify_ssd_restored' "$PROJECT_DIR/scripts/pi/health-check.sh" \
  || die "health-check SSD recovery notify yok"
grep -q 'apply-adguard-dns.sh' "$PROJECT_DIR/scripts/pi/adguard-tune.sh" \
  || die "adguard-tune apply-adguard-dns yok"
grep -q 'ensure-dns-perf-profile.sh' "$PROJECT_DIR/scripts/pi/post-deploy-code.sh" \
  || die "post-deploy-code ensure-dns-perf-profile yok"
grep -q '_log_partial_errors' "$PROJECT_DIR/scripts/lib/quake-alert.py" \
  || die "quake partial log rate-limit yok"
grep -q '_pi_home_script configure-adguard.sh' "$PROJECT_DIR/scripts/pi/ensure-adguard-blocking.sh" \
  || die "ensure-adguard full heal configure yok"
grep -q 'combined_original_trackers.txt' "$PROJECT_DIR/config/adguard/filter-lists.json" \
  || die "CNAME original_trackers aggressive profilde yok"
grep -q 'combined_disguised_trackers.txt' "$PROJECT_DIR/config/adguard/filter-lists.json" \
  && die "disguised CNAME listesi AGH icin yanlis (FP); original_trackers kullan"
grep -q 'unbound_dnssec_ad_ok' "$PROJECT_DIR/scripts/lib/unbound-dnssec.sh" \
  || die "unbound-dnssec AD probe yok"
grep -F '[[:space:]]ad;' "$PROJECT_DIR/scripts/lib/unbound-dnssec.sh" \
  || die "unbound-dnssec ADDITIONAL false-positive guard yok"
grep -q 'dnssec-failed.org' "$PROJECT_DIR/scripts/lib/unbound-dnssec.sh" \
  || die "unbound-dnssec sigfail probe yok"
grep -q 'Unbound DNSSEC' "$PROJECT_DIR/scripts/pi/diagnose-dns-bypass.sh" \
  || die "diagnose DNSSEC blogu yok"
grep -q 'unbound-dnssec-ad' "$PROJECT_DIR/scripts/pi/health-check.sh" \
  || die "health unbound-dnssec-ad yok"
grep -q 'unbound-dnssec-sigfail' "$PROJECT_DIR/scripts/pi/smoke-test.sh" \
  || die "smoke unbound-dnssec-sigfail yok"
grep -q 'privileged-adguard-filters-sync' "$PROJECT_DIR/scripts/pi/smoke-test.sh" \
  || die "smoke privileged-adguard-filters-sync yok"
grep -q 'adguard-no-popup-stack' "$PROJECT_DIR/scripts/pi/smoke-test.sh" \
  || die "smoke adguard-no-popup-stack yok"
grep -A25 'agh_no_popup_stack()' "$PROJECT_DIR/scripts/pi/smoke-test.sh" | grep -q 'trap ' \
  && die "agh_no_popup_stack RETURN trap set -u kirar"
[[ -f "$PROJECT_DIR/scripts/pi/export-adguard-metrics.sh" ]] || die "export-adguard-metrics.sh yok"
[[ -f "$PROJECT_DIR/scripts/lib/adguard-metrics.py" ]] || die "adguard-metrics.py yok"
bash "$PROJECT_DIR/scripts/pi/export-adguard-metrics.sh" --self-check \
  || die "export-adguard-metrics self-check"
grep -q 'sudo install -m 644' "$PROJECT_DIR/scripts/pi/export-adguard-metrics.sh" \
  || die "export-adguard-metrics sudo install yok (metrics dir root)"
grep -q 'ARG_MAX' "$PROJECT_DIR/scripts/pi/export-adguard-metrics.sh" \
  || die "export-adguard-metrics JSON dosyadan (ARG_MAX)"
grep -q 'export-adguard-metrics.sh' "$PROJECT_DIR/scripts/pi/install-privileged-scripts.sh" \
  || die "install-privileged export-adguard-metrics yok"
grep -q 'unbound-dnssec.sh' "$PROJECT_DIR/scripts/pi/install-privileged-scripts.sh" \
  || die "install-privileged unbound-dnssec yok"
grep -q 'apply-adguard-filters.sh' "$PROJECT_DIR/scripts/pi/install-privileged-scripts.sh" \
  || die "install-privileged apply-adguard-filters yok"
grep -q 'apply-adguard-dns.sh' "$PROJECT_DIR/scripts/pi/install-privileged-scripts.sh" \
  || die "install-privileged apply-adguard-dns yok"
grep -q 'ensure-adguard-blocking.sh' "$PROJECT_DIR/scripts/pi/install-privileged-scripts.sh" \
  || die "install-privileged ensure-adguard-blocking yok"
grep -q 'json.dumps' "$PROJECT_DIR/scripts/lib/adguard-api.sh" \
  || die "AdGuard login JSON encoder yok"
grep -q -- '--data-binary @-' "$PROJECT_DIR/scripts/lib/adguard-api.sh" \
  || die "AdGuard login encoded payload pipe yok"
grep -q 'apply-adguard-filters.sh' "$PROJECT_DIR/scripts/pi/post-deploy-code.sh" \
  || die "post-deploy-code apply-adguard-filters yok"
grep -q 'setup-rdnss-ra.sh' "$PROJECT_DIR/scripts/pi/post-deploy-code.sh" \
  || die "post-deploy-code setup-rdnss-ra yok"
grep -q 'pi_gateway_adguard_blocked_ratio' "$PROJECT_DIR/config/grafana/provisioning/dashboards/json/pi-gateway.json" \
  || die "grafana adguard blocked_ratio yok"
grep -q 'pi_gateway_adguard_filter_rules' "$PROJECT_DIR/config/grafana/provisioning/dashboards/json/pi-gateway.json" \
  || die "grafana adguard filter_rules yok"
grep -q 'filter_updated_timestamp' "$PROJECT_DIR/config/grafana/provisioning/dashboards/json/pi-gateway.json" \
  || die "grafana adguard last_updated age yok"
grep -q 'combined_original_trackers' "$PROJECT_DIR/docs/DNS-BLOCKING.md" \
  || die "DNS-BLOCKING CNAME original yok"
grep -q 'dnssec-failed.org' "$PROJECT_DIR/docs/DNS-BLOCKING.md" \
  || die "DNS-BLOCKING DNSSEC kontrat yok"
grep -q 'Popup Hosts' "$PROJECT_DIR/docs/DNS-BLOCKING.md" \
  || die "DNS-BLOCKING Popup Hosts not stacked notu yok"
grep -q 'REMOTE_DIR/scripts/pi/' "$PROJECT_DIR/docs/DNS-BLOCKING.md" \
  || die "DNS-BLOCKING health home SSOT yok"
grep -q 'PI_IPV6_ULA=' "$PROJECT_DIR/scripts/pi/discover-network.sh" \
  || die "discover-network PI_IPV6_ULA uretmiyor"
! grep -q 'source "\$ENV_FILE"' "$PROJECT_DIR/scripts/mac/discover-remote.sh" \
  || die "discover-remote generated .env shell-eval ediyor"

grep -q 'CANARY_DNS_WAIT_SEC:-10' "$PROJECT_DIR/scripts/pi/canary-compose-update.sh" \
  || die "canary DNS wait default 10 degil (45s yastik)"
grep -q 'POST_DEPLOY_RESTIC' "$PROJECT_DIR/scripts/pi/post-deploy.sh" \
  || die "post-deploy RESTIC skip yok"
grep -q 'POST_DEPLOY_RESTIC' "$PROJECT_DIR/.env.example" \
  || die ".env.example POST_DEPLOY_RESTIC yok"
echo "[test-dns-blocking] Tum kontroller gecti"
