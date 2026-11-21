#!/usr/bin/env bash
# CrowdSec kararlarini UFW'ye uygular (Docker LAPI + host UFW)
set -euo pipefail
REMOTE_DIR="${REMOTE_DIR:-/home/${USER}/pi-gateway}"
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
_PG_ENV_LIB="${SCRIPT_DIR:-$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)}/../lib/env-file.sh"
PG_SCRIPT_NAME="$(basename "$0")"
# shellcheck source=../lib/env-file.sh
source "${_PG_ENV_LIB:?}"
read_remote_dotenv || { echo "[${PG_SCRIPT_NAME:-script}] HATA: .env dotenv parser hatasi" >&2; exit 1; }
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
  local tmp_bouncer
  tmp_bouncer="$(umask 077 && mktemp)"
  cat >"$tmp_bouncer" <<EOF
mode: iptables
api_url: ${LAPI_URL}/
api_key: ${CROWDSEC_BOUNCER_KEY}
disable_ipv6: false
deny_action: DROP
deny_log: true
iptables_chains:
  - INPUT
  - DOCKER-USER
EOF
  sudo install -o root -g root -m 600 "$tmp_bouncer" /etc/crowdsec/bouncers/crowdsec-firewall-bouncer.yaml
  rm -f "$tmp_bouncer"
  sudo systemctl enable --now crowdsec-firewall-bouncer 2>/dev/null
  sudo systemctl restart crowdsec-firewall-bouncer 2>/dev/null || true
}
sync_ufw_decisions() {
  local sync_script="${SCRIPT_DIR}/sync-crowdsec-ufw.sh"
  [[ -x "$sync_script" ]] || sync_script="${REMOTE_DIR}/scripts/pi/sync-crowdsec-ufw.sh"
  if [[ -f "$sync_script" ]]; then
    REMOTE_DIR="$REMOTE_DIR" bash "$sync_script"
  fi
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
    sudo sed -i "s|/home/PI_USER/pi-gateway|${REMOTE_DIR}|g; s|PI_USER|${PI_USER:-$USER}|g" /etc/systemd/system/pi-gateway-crowdsec-ufw.*
    sudo systemctl daemon-reload
    sudo systemctl enable --now pi-gateway-crowdsec-ufw.timer
  fi
fi
log "Tamamlandi"
