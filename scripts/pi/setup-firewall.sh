#!/usr/bin/env bash
# UFW — Pi Gateway host guvenligi (SSH ban = CrowdSec, fail2ban yok)
set -euo pipefail
REMOTE_DIR="${REMOTE_DIR:-/home/${USER}/pi-gateway}"
LAN_SUBNET="${LAN_SUBNET_CIDR:-192.168.1.0/24}"
ENABLE_UFW="${ENABLE_UFW:-true}"
# full = tum admin portlari LAN | caddy-only = 80/443 disinda dogrudan port yok
UFW_ADMIN_EXPOSURE="${UFW_ADMIN_EXPOSURE:-caddy-only}"
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=../lib/env-file.sh
source "$SCRIPT_DIR/../lib/env-file.sh"
read_remote_dotenv || { echo "[firewall] HATA: .env dotenv parser hatasi" >&2; exit 1; }
LAN_SUBNET="${LAN_SUBNET_CIDR:-$LAN_SUBNET}"
ENABLE_UFW="${ENABLE_UFW:-true}"
UFW_ADMIN_EXPOSURE="${UFW_ADMIN_EXPOSURE:-caddy-only}"
log() { echo "[firewall] $*"; }
pkg_on_path() {
  command -v "$1" >/dev/null 2>&1 || [[ -x "/usr/sbin/$1" ]]
}
install_packages() {
  if pkg_on_path ufw; then
    return 0
  fi
  log "Paketler kuruluyor (ufw)..."
  sudo systemctl stop packagekit packagekit.service 2>/dev/null || true
  sudo systemctl stop unattended-upgrades 2>/dev/null || true
  if ! timeout 180 sudo apt-get update -qq; then
    log "HATA: apt-get update timeout — packagekit kapali mi?"
    return 1
  fi
  sudo DEBIAN_FRONTEND=noninteractive apt-get install -y -qq ufw
}
# Eski kurulumlardan fail2ban kalintisi — CrowdSec tek SSH bekci
purge_fail2ban_leftover() {
  sudo systemctl disable --now fail2ban 2>/dev/null || true
  sudo rm -f /etc/fail2ban/jail.d/pi-gateway.local 2>/dev/null || true
  if dpkg -l fail2ban 2>/dev/null | grep -q '^ii'; then
    log "fail2ban kaldiriliyor (CrowdSec yeterli)"
    sudo DEBIAN_FRONTEND=noninteractive apt-get purge -y -qq fail2ban 2>/dev/null || true
  fi
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
  # IPv6 DNS (ULA + istege bagli GUA LAN prefix)
  delete_ufw_rules_matching 'pi-gateway dns6'
  if [[ -n "${PI_IPV6_ULA:-}" ]]; then
    ula_net="$(python3 -c "import ipaddress,sys; a=ipaddress.ip_interface(sys.argv[1] if '/' in sys.argv[1] else sys.argv[1]+'/64'); print(a.network)" "${PI_IPV6_ULA}" 2>/dev/null || true)"
    if [[ -n "$ula_net" ]]; then
      sudo ufw allow from "$ula_net" to any port 53 proto tcp comment 'pi-gateway dns6'
      sudo ufw allow from "$ula_net" to any port 53 proto udp comment 'pi-gateway dns6'
      log "IPv6 DNS ULA: $ula_net"
    fi
  fi
  if [[ -n "${LAN_IPV6_CIDR:-}" ]]; then
    sudo ufw allow from "$LAN_IPV6_CIDR" to any port 53 proto tcp comment 'pi-gateway dns6'
    sudo ufw allow from "$LAN_IPV6_CIDR" to any port 53 proto udp comment 'pi-gateway dns6'
    log "IPv6 DNS LAN: $LAN_IPV6_CIDR"
  else
    # eth0 global GUA /64 (SLAAC LAN) — otomatik
    gua_net="$(ip -6 route show dev "${PI_INTERFACE:-eth0}" proto ra 2>/dev/null | awk '/\/64/{print $1; exit}')"
    if [[ -z "$gua_net" ]]; then
      gua_net="$(ip -6 addr show dev "${PI_INTERFACE:-eth0}" scope global 2>/dev/null | awk '/inet6/{print $2; exit}' | python3 -c "import sys,ipaddress; print(ipaddress.ip_interface(sys.stdin.read().strip()).network)" 2>/dev/null || true)"
    fi
    if [[ -n "$gua_net" && "$gua_net" != fe80:* ]]; then
      sudo ufw allow from "$gua_net" to any port 53 proto tcp comment 'pi-gateway dns6'
      sudo ufw allow from "$gua_net" to any port 53 proto udp comment 'pi-gateway dns6'
      log "IPv6 DNS GUA LAN: $gua_net"
    fi
  fi
  sudo ufw allow from fe80::/10 to any port 53 proto udp comment 'pi-gateway dns6'
  sudo ufw allow from fe80::/10 to any port 53 proto tcp comment 'pi-gateway dns6'
  if [[ "$UFW_ADMIN_EXPOSURE" == "caddy-only" ]]; then
    log "Admin modu: caddy-only (paneller yalnizca *.home / Tailscale uzerinden 80/443)"
    for port in 80 443; do
      delete_ufw_rules_matching "pi-gateway $port"
      sudo ufw allow from "$LAN_SUBNET" to any port "$port" proto tcp comment "pi-gateway $port"
    done
    for port in 3001 3040 5678 8080 9999; do
      delete_lan_admin_port "$port"
    done
  else
    for port in 80 443 3001 3040 5678 8080 9999; do
      delete_ufw_rules_matching "pi-gateway $port"
      sudo ufw allow from "$LAN_SUBNET" to any port "$port" proto tcp comment "pi-gateway $port"
    done
  fi
  # REMOVED: syncthing 22000 / forgejo 3002 — eski kurulumlardan temizle
  delete_ufw_rules_matching 'pi-gateway syncthing'
  delete_lan_admin_port 3002
  delete_lan_admin_port 8384
  delete_ufw_rules_matching 'pi-gateway docker-adguard'
  delete_ufw_rules_matching 'pi-gateway docker-bridge-adguard'
  delete_ufw_rules_matching 'pi-gateway docker-caddy-adguard'
  # AdGuard host network — compose_default + genis docker bridge (subnet drift)
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
  # Ek docker bridge subnet'leri (172.16/12 yerine gercek CIDR)
  while IFS= read -r _dock_subnet; do
    [[ -n "$_dock_subnet" ]] || continue
    [[ "$_dock_subnet" == "$compose_subnet" ]] && continue
    sudo ufw allow from "$_dock_subnet" to any port 8080 proto tcp comment 'pi-gateway docker-bridge-adguard'
    if [[ "${ENABLE_NETALERTX:-true}" == "true" ]]; then
      sudo ufw allow from "$_dock_subnet" to any port "${NETALERTX_PORT:-20211}" proto tcp comment 'pi-gateway docker-bridge-netalertx'
    fi
  done < <(docker network ls -q 2>/dev/null | while read -r _nid; do
    [[ -n "$_nid" ]] || continue
    docker network inspect "$_nid" -f '{{range .IPAM.Config}}{{.Subnet}}{{println}}{{end}}' 2>/dev/null
  done | awk 'NF' | sort -u)
  if ! docker network ls -q 2>/dev/null | grep -q .; then
    log "WARN: docker ag yok — docker0 fallback 172.17.0.0/16"
    sudo ufw allow from 172.17.0.0/16 to any port 8080 proto tcp comment 'pi-gateway docker0-adguard-fallback'
    if [[ "${ENABLE_NETALERTX:-true}" == "true" ]]; then
      sudo ufw allow from 172.17.0.0/16 to any port "${NETALERTX_PORT:-20211}" proto tcp comment 'pi-gateway docker0-netalertx-fallback'
    fi
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
main() {
  install_packages
  purge_fail2ban_leftover
  setup_ufw
  log "Tamamlandi"
}
main "$@"
