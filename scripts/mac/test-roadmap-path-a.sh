#!/usr/bin/env bash
# Path A (Guven) roadmap contracts
set -euo pipefail
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ROOT="$(cd "$SCRIPT_DIR/../.." && pwd)"
die() { echo "[test-roadmap] HATA: $*" >&2; exit 1; }
ok() { echo "[test-roadmap] OK: $*"; }

grep -q 'export-gateway-state' "$ROOT/scripts/pi/health-check.sh" || die "health export-gateway-state yok"
grep -q 'push-slo-heartbeat' "$ROOT/scripts/pi/health-check.sh" || die "health push-slo yok"
grep -q 'backup-restore-drill' "$ROOT/scripts/pi/health-check.sh" || die "health drill SLA yok"
ok "health wiring"

[[ -f "$ROOT/scripts/pi/export-gateway-state.sh" ]] || die "export-gateway-state.sh yok"
grep -q 'pi_gateway_storage_degraded' "$ROOT/scripts/pi/export-gateway-state.sh" || die "prometheus metrics yok"
grep -q 'export-adguard-metrics.sh' "$ROOT/scripts/pi/export-gateway-state.sh" || die "export-state adguard scrape yok"
ok "state exporter"

[[ -f "$ROOT/scripts/mac/backup-restore-drill.sh" ]] || die "backup-restore-drill.sh yok"
grep -q 'restic restore' "$ROOT/scripts/mac/backup-restore-drill.sh" || die "drill restore yok"
grep -q 'backup-restore-drill' "$ROOT/Makefile" || die "Makefile backup-restore-drill yok"
ok "restore drill"

[[ -f "$ROOT/scripts/pi/check-ssd-smart.sh" ]] || die "check-ssd-smart.sh yok"
[[ -f "$ROOT/host/systemd/pi-gateway-ssd-smart.timer" ]] || die "ssd-smart timer yok"
grep -q 'smartmontools' "$ROOT/scripts/pi/setup-ssd-smart-timer.sh" || die "setup-ssd-smart-timer smartmontools yok"
grep -q '/usr/sbin/smartctl' "$ROOT/scripts/pi/check-ssd-smart.sh" || die "check-ssd-smart sbin PATH yok"
grep -q 'pi-gateway-ssd-smart.timer' "$ROOT/docs/OPERATIONS.md" || die "OPERATIONS SMART runbook yok"
ok "SMART timer"

[[ -f "$ROOT/scripts/pi/restic-offsite-copy.sh" ]] || die "restic-offsite-copy yok"
grep -q 'RESTIC_OFFSITE_ENABLED' "$ROOT/.env.example" || die "env offsite yok"
grep -q 'restic-offsite-copy' "$ROOT/scripts/pi/restic-backup.sh" || die "restic offsite wire yok"
ok "B2/R2 offsite copy"

[[ -f "$ROOT/scripts/mac/config-drift-check.sh" ]] || die "config-drift yok"
grep -q 'config-drift' "$ROOT/Makefile" || die "Makefile config-drift yok"
ok "config drift"

[[ -f "$ROOT/docs/SLO.md" ]] || die "SLO.md yok"
[[ -f "$ROOT/scripts/pi/setup-slo-monitors.sh" ]] || die "setup-slo-monitors yok"
[[ -f "$ROOT/scripts/pi/push-slo-heartbeat.sh" ]] || die "push-slo-heartbeat yok"
grep -q 'setup-slo-monitors' "$ROOT/scripts/pi/post-deploy.sh" || die "post-deploy slo yok"
ok "SLO monitors"

grep -q 'post-deploy-integration' "$ROOT/scripts/pi/post-deploy.sh" || die "post-deploy integration yok"
grep -q 'POST_DEPLOY_RESTIC' "$ROOT/scripts/pi/post-deploy.sh" || die "post-deploy restic skip yok"
ok "post-deploy integration"

echo "[test-roadmap] Tum kontroller gecti"
