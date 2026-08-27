#!/usr/bin/env bash
# Path B visibility stack contracts
set -euo pipefail
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
die() { echo "[test-path-b] HATA: $*" >&2; exit 1; }

grep -q 'ENABLE_MONITORING' "$ROOT/scripts/lib/compose-profiles.sh" || die "monitoring profile yok"
grep -q 'prometheus:' "$ROOT/compose/docker-compose.yml" || die "prometheus servisi yok"
grep -q 'grafana:' "$ROOT/compose/docker-compose.yml" || die "grafana servisi yok"
grep -q 'node-exporter:' "$ROOT/compose/docker-compose.yml" || die "node-exporter yok"
[[ -f "$ROOT/config/prometheus/prometheus.yml" ]] || die "prometheus.yml yok"
[[ -f "$ROOT/config/grafana/provisioning/datasources/prometheus.yml" ]] || die "grafana datasource yok"
[[ -f "$ROOT/config/grafana/provisioning/dashboards/json/pi-gateway.json" ]] || die "grafana dashboard yok"
grep -q 'grafana\.' "$ROOT/config/caddy/Caddyfile.tls.template" || die "caddy grafana route yok"
grep -q 'grafana' "$ROOT/config/homepage/services.yaml.template" || die "homepage grafana yok"
grep -q 'canary-compose-update' "$ROOT/scripts/mac/deploy.sh" || die "deploy canary wire yok"
grep -q 'apply-adguard-rewrites.sh' "$ROOT/scripts/pi/canary-compose-update.sh" \
  || die "canary rewrite apply yok"
! grep -q 'MIN_REWRITES' "$ROOT/scripts/pi/wait-adguard-dns.sh" \
  || die "wait-adguard hala rewrite kapisi (canary deadlock)"
grep -q 'pi_gateway_adguard_blocked_ratio' "$ROOT/config/grafana/provisioning/dashboards/json/pi-gateway.json" \
  || die "grafana adguard blocked_ratio yok"
[[ -f "$ROOT/docs/VISIBILITY.md" ]] || die "VISIBILITY.md yok"
echo "[test-path-b] OK"
