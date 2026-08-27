#!/usr/bin/env bash
# systemd oneshot stale 'failed' — yalnız sağlık artefact + first-boot gürültü.
# Yedek / SSD setup oneshot'ları listeye koyma (gerçek fail gizlenmesin).
reset_pi_gateway_failed_units() {
  local u units=(
    pi-gateway-health pi-ssd-health pi-ssd-watch
    cloud-init-local cloud-config cloud-init-network cloud-init-main
    rp1-test
  )
  for u in "${units[@]}"; do
    systemctl reset-failed "${u}.service" 2>/dev/null \
      || sudo systemctl reset-failed "${u}.service" 2>/dev/null \
      || true
  done
}

if [[ "${BASH_SOURCE[0]}" == "${0}" ]]; then
  reset_pi_gateway_failed_units
fi
