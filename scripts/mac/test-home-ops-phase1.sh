#!/usr/bin/env bash
# Faz 1: Telegram mimari + kart + A4/A5/B2/B3/B4
set -euo pipefail
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
die() { echo "[test-home-ops] HATA: $*" >&2; exit 1; }
ok() { echo "[test-home-ops] OK: $*"; }

health="$ROOT/scripts/pi/health-check.sh"
! grep -q 'notify_dns_fail' "$health" || die "health-check hâlâ notify_dns_fail"
! grep -q 'notify_dns_recovered' "$health" || die "health-check hâlâ notify_dns_recovered"
grep -q 'telegram-status-card.sh' "$health" || die "health-check durum kartı yok"
ok "health-dns çift kesildi + kart"

n8n="$ROOT/scripts/pi/setup-n8n-workflows.sh"
grep -q 'deactivate_workflow "Pi Gateway — Uptime Kuma Alert"' "$n8n" \
  || die "n8n Kuma deactivate yok"
grep -q 'delete_notification' "$ROOT/scripts/pi/setup-uptime-kuma.sh" \
  || die "Kuma notification silme yok"
grep -q 'n8n-kuma-telegram-off' "$ROOT/scripts/pi/smoke-test.sh" \
  || die "smoke kuma telegram-off yok"
ok "Kuma Telegram kapali"

card="$ROOT/scripts/lib/telegram-status-card.py"
[[ -f "$card" ]] || die "telegram-status-card.py yok"
python3 "$card" self-check || die "status-card self-check"
grep -q 'editMessageText' "$card" || die "editMessageText yok"
grep -q 'telegram-status-card.sh' "$ROOT/scripts/pi/telegram-menu.sh" \
  || die "telegram-menu kart kullanmiyor"
grep -q 'Ana' "$ROOT/scripts/lib/telegram-panels.py" || die "TR Ana etiket yok"
grep -q 'Grafikler' "$ROOT/scripts/lib/telegram-panels.py" || die "TR Grafikler yok"
ok "durum karti + TR menu"

python3 "$ROOT/scripts/lib/gateway-probes.py" --self-check || die "gateway-probes"
python3 "$ROOT/scripts/lib/quake-alert.py" --self-check || die "quake-alert"
bash "$ROOT/scripts/pi/kuma-monthly-report.sh" --self-check || die "kuma-report"
bash "$ROOT/scripts/pi/isp-speedtest.sh" --self-check || die "speedtest"
bash "$ROOT/scripts/pi/export-adguard-metrics.sh" --self-check || die "adguard-metrics"
bash "$ROOT/scripts/pi/ibb-air-quality.sh" --self-check || die "ibb-air"
ok "A4 A5 B2 B4 self-check"

grep -q 'pi_gateway_dns_latency_ms' "$ROOT/scripts/lib/gateway-probes.py" \
  || die "dns latency metrik yok"
grep -q 'pi_gateway_video_dns_latency_ms' "$ROOT/scripts/lib/gateway-probes.py" \
  || die "video dns latency metrik yok"
grep -q 'pi_gateway_netalert_db_readable' "$ROOT/scripts/lib/gateway-probes.py" \
  || die "netalert db readability metrik yok"
grep -q 'notify_latency_slow' "$ROOT/scripts/lib/notify.sh" || die "latency notify yok"
grep -q 'pi_gateway_dns_latency_ms' "$ROOT/config/grafana/provisioning/dashboards/json/pi-gateway.json" \
  || die "grafana dns latency yok"
grep -q 'pi_gateway_isp_download_mbps' "$ROOT/config/grafana/provisioning/dashboards/json/pi-gateway.json" \
  || die "grafana speedtest yok"
grep -q 'pi_gateway_hosts_online' "$ROOT/config/grafana/provisioning/dashboards/json/pi-gateway.json" \
  || die "grafana kim-evde yok"
grep -q 'pi_gateway_adguard_blocked_ratio' "$ROOT/config/grafana/provisioning/dashboards/json/pi-gateway.json" \
  || die "grafana adguard blocked_ratio yok"
grep -q 'pi_gateway_adguard_top_client_queries' "$ROOT/scripts/lib/adguard-metrics.py" \
  || die "adguard top_client metrik yok"
grep -q 'pi_gateway_adguard_top_client_queries' "$ROOT/config/grafana/provisioning/dashboards/json/pi-gateway.json" \
  || die "grafana adguard top clients yok"
grep -q 'pi_gateway_ibb_hki' "$ROOT/config/grafana/provisioning/dashboards/json/pi-gateway.json" \
  || die "grafana ibb hki yok"
grep -q 'notify_ibb_hki_warn' "$ROOT/scripts/lib/notify.sh" || die "ibb notify yok"
grep -q 'who_home' "$ROOT/config/homepage/services.yaml.template" || die "homepage kim-evde yok"
grep -q 'def online_devices' "$ROOT/scripts/lib/netalert-devices.py" || die "online_devices yok"
ok "A5 B2 B3 panolar"

[[ -f "$ROOT/host/systemd/pi-gateway-kuma-report.timer" ]] || die "kuma timer yok"
[[ -f "$ROOT/host/systemd/pi-gateway-speedtest.timer" ]] || die "speedtest timer yok"
[[ -f "$ROOT/host/systemd/pi-gateway-ibb.timer" ]] || die "ibb timer yok"
grep -q 'pi-gateway-ibb.timer' "$ROOT/scripts/pi/setup-home-ops-timers.sh" \
  || die "home-ops ibb timer yok"
grep -q 'sudo install -m 644' "$ROOT/scripts/pi/ibb-air-quality.sh" \
  || die "ibb metrics sudo install yok"
grep -qF 'OnCalendar=*:0/30' "$ROOT/host/systemd/pi-gateway-ibb.timer" \
  || die "ibb timer 30dk calendar yok"
grep -q 'setup-home-ops-timers.sh' "$ROOT/scripts/pi/post-deploy-code.sh" \
  || die "code deploy home-ops timers yok"
grep -q 'OnUnitActiveSec=30s' "$ROOT/host/systemd/pi-gateway-quake.timer" \
  || die "quake timer 30s degil"
grep -q 'fetch_kandilli\|Kandilli' "$ROOT/scripts/lib/quake-alert.py" \
  || die "kandilli kaynagi yok"
grep -q 'bootstrapped' "$ROOT/scripts/lib/quake-alert.py" \
  || die "quake bootstrap yok"
grep -q 'ThreadPoolExecutor\|flock' "$ROOT/scripts/lib/quake-alert.py" \
  "$ROOT/scripts/pi/quake-alert.sh" \
  || die "quake parallel/flock yok"
grep -q 'TimeoutStartSec' "$ROOT/host/systemd/pi-gateway-quake.service" \
  || die "quake TimeoutStartSec yok"
grep -q 'setup-home-ops-timers.sh' "$ROOT/scripts/pi/post-deploy.sh" \
  || die "post-deploy home-ops timers yok"
grep -q 'pi-gateway-quake.timer' "$ROOT/scripts/pi/bootstrap.sh" || die "bootstrap quake yok"
grep -q 'pi-gateway-ibb.timer' "$ROOT/scripts/pi/bootstrap.sh" || die "bootstrap ibb yok"
ok "timer wiring"

grep -q 'LOCAL_MAG' "$ROOT/scripts/lib/quake-alert.py" || die "deprem esik yok"
grep -q 'is_aftershock' "$ROOT/scripts/lib/quake-alert.py" || die "artci yok"
grep -q 'hour_blocked' "$ROOT/scripts/lib/quake-alert.py" || die "saat tavan yok"
ok "B4 deprem filtre"

echo "[test-home-ops] Tum kontroller gecti"
