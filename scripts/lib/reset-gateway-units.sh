#!/usr/bin/env bash
# systemd oneshot stale 'failed' — yalnız sağlık artefact + first-boot gürültü.
# Yedek / SSD setup oneshot'ları listeye koyma (gerçek fail gizlenmesin).
reset_pi_gateway_failed_units() {
  local u units=(
    pi-gateway-health pi-ssd-health pi-ssd-watch
    cloud-init-local cloud-config cloud-init-network cloud-init-main
    rp1-test
  )
  local checked_sudo=0 can_sudo=0
  for u in "${units[@]}"; do
    systemctl is-failed --quiet "${u}.service" 2>/dev/null || continue
    if (( EUID == 0 )); then
      systemctl reset-failed "${u}.service" 2>/dev/null || true
    else
      if (( ! checked_sudo )); then
        checked_sudo=1
        sudo -n true 2>/dev/null && can_sudo=1
      fi
      if (( can_sudo )); then
        sudo -n systemctl reset-failed "${u}.service" 2>/dev/null || true
      fi
    fi
  done
}

if [[ "${BASH_SOURCE[0]}" == "${0}" ]]; then
  reset_pi_gateway_failed_units
fi
