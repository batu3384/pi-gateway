#!/usr/bin/env bash
# UFW + fail2ban — Pi Gateway host guvenligi
set -euo pipefail
REMOTE_DIR="${REMOTE_DIR:-/home/${USER}/pi-gateway}"
LAN_SUBNET="${LAN_SUBNET_CIDR:-192.168.1.0/24}"
ENABLE_UFW="${ENABLE_UFW:-true}"
ENABLE_FAIL2BAN="${ENABLE_FAIL2BAN:-true}"
# full = tum admin portlari LAN | caddy-only = 80/443 disinda dogrudan port yok
UFW_ADMIN_EXPOSURE="${UFW_ADMIN_EXPOSURE:-caddy-only}"
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=../lib/env-file.sh
source "$SCRIPT_DIR/../lib/env-file.sh"
read_remote_dotenv || { echo "[firewall] HATA: .env dotenv parser hatasi" >&2; exit 1; }
LAN_SUBNET="${LAN_SUBNET_CIDR:-$LAN_SUBNET}"
ENABLE_UFW="${ENABLE_UFW:-true}"
ENABLE_FAIL2BAN="${ENABLE_FAIL2BAN:-true}"
UFW_ADMIN_EXPOSURE="${UFW_ADMIN_EXPOSURE:-caddy-only}"
log() { echo "[firewall] $*"; }
pkg_on_path() {
  command -v "$1" >/dev/null 2>&1 || [[ -x "/usr/sbin/$1" ]]
}
install_packages() {
  if pkg_on_path ufw && pkg_on_path fail2ban-client; then
    return 0
  fi
  log "Paketler kuruluyor (ufw, fail2ban)..."
  sudo systemctl stop packagekit packagekit.service 2>/dev/null || true
  sudo systemctl stop unattended-upgrades 2>/dev/null || true
  if ! timeout 180 sudo apt-get update -qq; then
    log "HATA: apt-get update timeout — packagekit kapali mi?"
    return 1
  fi
  sudo DEBIAN_FRONTEND=noninteractive apt-get install -y -qq ufw fail2ban
}
tailscale_connected() {
  command -v tailscale >/dev/null 2>&1 || return 1
  tailscale status --json 2>/dev/null | python3 -c \
    "import json,sys; d=json.load(sys.stdin); sys.exit(0 if d.get('BackendState')=='Running' else 1)" 2>/dev/null
}
ufw_rule_num() {
  sed -n 's/^[[:space:]]*\[[[:space:]]*\([0-9]*\)\].*/\1/p' | head -1
}
delete_lan_admin_port() {
  local port="$1"
  local attempt=0
  while (( attempt < 20 )); do
    local num
    num="$(sudo ufw status numbered 2>/dev/null | grep -F "pi-gateway $port" | grep -F "$LAN_SUBNET" | ufw_rule_num || true)"
    [[ -n "$num" ]] || break
    sudo ufw --force delete "$num" >/dev/null 2>&1 || break
    attempt=$((attempt + 1))
  done
}
delete_ufw_rules_matching() {
  local pattern="$1"
  local extra="${2:-}"
  local num
  while true; do
    num="$(sudo ufw status numbered 2>/dev/null | grep -F "$pattern" | { [[ -n "$extra" ]] && grep -F "$extra" || cat; } | ufw_rule_num || true)"
    [[ -n "$num" ]] || break
    sudo ufw --force delete "$num" >/dev/null 2>&1 || break
  done
}
setup_ufw() {
  [[ "$ENABLE_UFW" == "true" ]] || { log "UFW atlandi (ENABLE_UFW=false)"; return 0; }
  log "UFW yapilandiriliyor (LAN: $LAN_SUBNET, mod: $UFW_ADMIN_EXPOSURE)"
  sudo ufw default deny incoming
  sudo ufw default allow outgoing
  sudo ufw default deny routed
  while sudo ufw status numbered 2>/dev/null | grep -F 'pi-gateway dns' | grep -q 'Anywhere'; do
    delete_ufw_rules_matching 'pi-gateway dns' 'Anywhere'
  done
  delete_ufw_rules_matching 'pi-gateway dns'
  delete_ufw_rules_matching 'pi-gateway ssh'
  sudo ufw allow from "$LAN_SUBNET" to any port 22 proto tcp comment 'pi-gateway ssh'
  sudo ufw allow from "$LAN_SUBNET" to any port 53 proto tcp comment 'pi-gateway dns'
  sudo ufw allow from "$LAN_SUBNET" to any port 53 proto udp comment 'pi-gateway dns'
  if [[ "$UFW_ADMIN_EXPOSURE" == "caddy-only" ]]; then
    log "Admin modu: caddy-only (paneller yalnizca *.home / Tailscale uzerinden 80/443)"
    for port in 80 443; do
      delete_ufw_rules_matching "pi-gateway $port"
      sudo ufw allow from "$LAN_SUBNET" to any port "$port" proto tcp comment "pi-gateway $port"
    done
    for port in 3001 3002 3040 5678 8080 8384 9999; do
      delete_lan_admin_port "$port"
    done
  else
    for port in 80 443 3001 3002 3040 5678 8080 8384 9999; do
      delete_ufw_rules_matching "pi-gateway $port"
      sudo ufw allow from "$LAN_SUBNET" to any port "$port" proto tcp comment "pi-gateway $port"
    done
  fi
  delete_ufw_rules_matching 'pi-gateway syncthing'
  sudo ufw allow from "$LAN_SUBNET" to any port 22000 proto tcp comment 'pi-gateway syncthing-tcp'
  sudo ufw allow from "$LAN_SUBNET" to any port 22000 proto udp comment 'pi-gateway syncthing-udp'
  delete_ufw_rules_matching 'pi-gateway docker-adguard'
  # AdGuard host network — yalnizca compose agi (Caddy -> AdGuard :8080)
  compose_subnet="$(docker network inspect compose_default -f '{{range .IPAM.Config}}{{.Subnet}}{{end}}' 2>/dev/null || true)"
  if [[ -n "$compose_subnet" ]]; then
    sudo ufw allow from "$compose_subnet" to any port 8080 proto tcp comment 'pi-gateway docker-adguard'
    if [[ "${ENABLE_NETALERTX:-true}" == "true" ]]; then
      delete_ufw_rules_matching 'pi-gateway docker-netalertx'
      netalert_port="${NETALERTX_PORT:-20211}"
      graphql_port="${NETALERTX_GRAPHQL_PORT:-20214}"
      sudo ufw allow from "$compose_subnet" to any port "$netalert_port" proto tcp comment 'pi-gateway docker-netalertx'
      sudo ufw allow from "$compose_subnet" to any port "$graphql_port" proto tcp comment 'pi-gateway docker-netalertx-graphql'
    fi
  else
    log "WARN: compose_default subnet bulunamadi — docker-adguard UFW kurali atlandi"
  fi
  delete_ufw_rules_matching 'pi-gateway tailscale'
  delete_ufw_rules_matching 'pi-gateway ts-subnet'
  if tailscale_connected; then
    for port in 22 80 443; do
      sudo ufw allow in on tailscale0 to any port "$port" proto tcp comment "pi-gateway tailscale-$port"
    done
    log "Tailscale bagli — tailscale0: 22/80/443 (admin panelleri Caddy uzerinden)"
  else
    log "Tailscale bagli degil — tailscale0 kurali eklenmedi"
  fi
  sudo ufw --force enable
  sudo ufw status numbered
  log "UFW aktif"
}
setup_fail2ban() {
  [[ "$ENABLE_FAIL2BAN" == "true" ]] || { log "fail2ban atlandi"; return 0; }
  local jail_dir="/etc/fail2ban/jail.d"
  sudo mkdir -p "$jail_dir"
  if [[ -f "$REMOTE_DIR/host/fail2ban/pi-gateway.local" ]]; then
    sudo cp "$REMOTE_DIR/host/fail2ban/pi-gateway.local" "$jail_dir/pi-gateway.local"
  else
    sudo tee "$jail_dir/pi-gateway.local" >/dev/null <<'EOF'
[DEFAULT]
bantime  = 1h
findtime = 10m
maxretry = 5
backend = systemd
[sshd]
enabled = true
port    = ssh
filter  = sshd
maxretry = 4
bantime  = 2h
EOF
  fi
  sudo systemctl enable fail2ban
  sudo systemctl restart fail2ban
  sudo fail2ban-client status sshd 2>/dev/null || sudo fail2ban-client status
  log "fail2ban aktif"
}
main() {
  install_packages
  setup_ufw
  setup_fail2ban
  log "Tamamlandi"
}
main "$@"
