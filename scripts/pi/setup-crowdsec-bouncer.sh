#!/usr/bin/env bash
# CrowdSec kararlarini UFW'ye uygular (Docker LAPI + host UFW)
set -euo pipefail

REMOTE_DIR="${REMOTE_DIR:-/home/${USER}/pi-gateway}"
# shellcheck source=/dev/null
[[ -f "$REMOTE_DIR/.env" ]] && source "$REMOTE_DIR/.env"

log() { echo "[crowdsec-bouncer] $*"; }

docker ps --format '{{.Names}}' | grep -q '^crowdsec$' || {
  log "crowdsec container yok — atlandi"
  exit 0
}

install_host_bouncer() {
  if command -v crowdsec-firewall-bouncer >/dev/null 2>&1; then
    return 0
  fi
  log "Host bouncer deneniyor (apt)..."
  if curl -fsSL https://install.crowdsec.net | sudo sh 2>/dev/null; then
    sudo apt-get install -y -qq crowdsec-firewall-bouncer-iptables 2>/dev/null && return 0
  fi
  return 1
}

configure_host_bouncer() {
  local key
  BOUNCER_NAME="${CROWDSEC_BOUNCER_NAME:-pi-firewall-bouncer}"
  LAPI_URL="${CROWDSEC_LAPI_URL:-http://127.0.0.1:8082}"

  if [[ -z "${CROWDSEC_BOUNCER_KEY:-}" ]]; then
    key="$(docker exec crowdsec cscli bouncers add "$BOUNCER_NAME" -o raw 2>/dev/null | tail -1 || true)"
    [[ -n "$key" ]] || return 1
    CROWDSEC_BOUNCER_KEY="$key"
    grep -q '^CROWDSEC_BOUNCER_KEY=' "$REMOTE_DIR/.env" 2>/dev/null && \
      sed -i "s|^CROWDSEC_BOUNCER_KEY=.*|CROWDSEC_BOUNCER_KEY=${key}|" "$REMOTE_DIR/.env" || \
      echo "CROWDSEC_BOUNCER_KEY=${key}" >> "$REMOTE_DIR/.env"
  fi

  sudo mkdir -p /etc/crowdsec/bouncers
  sudo tee /etc/crowdsec/bouncers/crowdsec-firewall-bouncer.yaml >/dev/null <<EOF
mode: iptables
api_url: ${LAPI_URL}/
api_key: ${CROWDSEC_BOUNCER_KEY}
disable_ipv6: false
deny_action: DROP
deny_log: true
iptables_chains:
  - INPUT
EOF
  sudo systemctl enable --now crowdsec-firewall-bouncer 2>/dev/null
}

sync_ufw_decisions() {
  local ip
  while read -r ip; do
    [[ -n "$ip" ]] || continue
    sudo ufw status | grep -qF "$ip" && continue
    sudo ufw deny from "$ip" comment "crowdsec" 2>/dev/null || true
    log "UFW deny: $ip"
  done < <(docker exec crowdsec cscli decisions list -o raw 2>/dev/null | awk '{print $1}' | grep -E '^[0-9]+\.' || true)
}

if install_host_bouncer && configure_host_bouncer; then
  log "Host firewall bouncer aktif"
else
  log "Host bouncer yok — UFW senkron modu (timer ile)"
  sync_ufw_decisions
  TIMER_SRC="$REMOTE_DIR/host/systemd/pi-gateway-crowdsec-ufw.timer"
  SVC_SRC="$REMOTE_DIR/host/systemd/pi-gateway-crowdsec-ufw.service"
  if [[ -f "$TIMER_SRC" ]]; then
    sudo cp "$TIMER_SRC" "$SVC_SRC" /etc/systemd/system/
    sudo sed -i "s|PI_USER|${USER}|g; s|/home/PI_USER/pi-gateway|${REMOTE_DIR}|g" /etc/systemd/system/pi-gateway-crowdsec-ufw.*
    sudo systemctl daemon-reload
    sudo systemctl enable --now pi-gateway-crowdsec-ufw.timer
  fi
fi

log "Tamamlandi"
