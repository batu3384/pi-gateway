#!/usr/bin/env bash
# systemd oneshot birimlerinde stale 'failed' durumunu temizle (deploy artifact).
reset_pi_gateway_failed_units() {
  local u units=(pi-gateway-health pi-gateway-stack-watchdog pi-ssd-health pi-ssd-watch)
  for u in "${units[@]}"; do
    systemctl reset-failed "${u}.service" 2>/dev/null \
      || sudo systemctl reset-failed "${u}.service" 2>/dev/null \
      || true
  done
}

if [[ "${BASH_SOURCE[0]}" == "${0}" ]]; then
  reset_pi_gateway_failed_units
fi
