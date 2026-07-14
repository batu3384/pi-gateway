#!/usr/bin/env bash
# Tailscale: ev LAN subnet router (*.home uzaktan icin) + ip forward
set -euo pipefail

REMOTE_DIR="${REMOTE_DIR:-/home/${USER}/pi-gateway}"
# shellcheck source=/dev/null
[[ -f "$REMOTE_DIR/.env" ]] && source "$REMOTE_DIR/.env"

LAN_SUBNET="${LAN_SUBNET_CIDR:-192.168.1.0/24}"
LAN_DOMAIN="${LAN_DOMAIN:-home}"
PI_INTERFACE="${PI_INTERFACE:-eth0}"
TS_DNS_CONF="/etc/sysctl.d/99-pi-gateway-tailscale.conf"

log() { echo "[tailscale-remote] $*"; }

command -v tailscale >/dev/null 2>&1 || { log "tailscale yok"; exit 1; }

if ! tailscale status --json 2>/dev/null | python3 -c \
  "import json,sys; sys.exit(0 if json.load(sys.stdin).get('BackendState')=='Running' else 1)"; then
  log "HATA: Tailscale bagli degil — once tailscale up"
  exit 1
fi

if ! grep -q 'net.ipv4.ip_forward' "$TS_DNS_CONF" 2>/dev/null; then
  log "ip_forward aciliyor"
  echo 'net.ipv4.ip_forward = 1' | sudo tee "$TS_DNS_CONF" >/dev/null
  sudo sysctl -p "$TS_DNS_CONF" >/dev/null
fi

if [[ -f /etc/default/ufw ]] && grep -q '^DEFAULT_FORWARD_POLICY=' /etc/default/ufw; then
  if ! grep -q '^DEFAULT_FORWARD_POLICY="ACCEPT"' /etc/default/ufw; then
    log "UFW forward policy ACCEPT"
    sudo sed -i 's/^DEFAULT_FORWARD_POLICY=.*/DEFAULT_FORWARD_POLICY="ACCEPT"/' /etc/default/ufw
    sudo ufw reload >/dev/null 2>&1 || true
  fi
fi

sudo ufw route allow in on tailscale0 out on "${PI_INTERFACE}" comment 'pi-gateway ts-subnet' 2>/dev/null || \
  sudo ufw route allow in on tailscale0 2>/dev/null || true

TS_IP="$(tailscale ip -4 2>/dev/null | head -1)"
log "Subnet route reklam: ${LAN_SUBNET}"
sudo tailscale set --advertise-routes="${LAN_SUBNET}" --accept-routes=false

log "Tamamlandi"
log ""
log "=== Senin yapman gereken (bir kez, tarayici) ==="
log "1) https://login.tailscale.com/admin/dns"
log "   Nameserver: ${TS_IP}"
log "   Split DNS domain: ${LAN_DOMAIN}"
log "   'Override local DNS' ac (telefon/Mac uzaktan *.${LAN_DOMAIN} icin)"
log "2) https://login.tailscale.com/admin/machines"
log "   pi-gateway -> Edit route settings -> ${LAN_SUBNET} ONAYLA"
log ""
log "Sonra telefonda Tailscale acikken: http://gateway.${LAN_DOMAIN}"
