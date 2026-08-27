#!/usr/bin/env bash
# Tailscale: ev LAN subnet router (*.home uzaktan icin) + ip forward
set -euo pipefail
REMOTE_DIR="${REMOTE_DIR:-/home/${USER}/pi-gateway}"
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
_PG_ENV_LIB="${SCRIPT_DIR:-$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)}/../lib/env-file.sh"
PG_SCRIPT_NAME="$(basename "$0")"
# shellcheck source=../lib/env-file.sh
source "${_PG_ENV_LIB:?}"
read_remote_dotenv || { echo "[${PG_SCRIPT_NAME:-script}] HATA: .env dotenv parser hatasi" >&2; exit 1; }
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
# Subnet router icin UFW forward gerekir; yalnızca aşağıdaki port route'ları açık.
if [[ -f /etc/default/ufw ]] && grep -q '^DEFAULT_FORWARD_POLICY=' /etc/default/ufw; then
  if ! grep -q '^DEFAULT_FORWARD_POLICY="DROP"' /etc/default/ufw; then
    log "UFW forward policy DROP (Tailscale subnet router — allowlist)"
    sudo sed -i 's/^DEFAULT_FORWARD_POLICY=.*/DEFAULT_FORWARD_POLICY="DROP"/' /etc/default/ufw
    sudo ufw reload >/dev/null 2>&1 || true
  fi
fi
# Sadece tailscale0 -> LAN gateway/DNS/sync portları; genel forward kapalı.
while sudo ufw status numbered 2>/dev/null | grep -F 'pi-gateway ts-subnet' | grep -q .; do
  num="$(sudo ufw status numbered 2>/dev/null | sed -n 's/^[[:space:]]*\[[[:space:]]*\([0-9]*\)\].*pi-gateway ts-subnet.*/\1/p' | head -1)"
  [[ -n "$num" ]] || break
  sudo ufw --force delete "$num" >/dev/null 2>&1 || break
done
sudo ufw route allow in on tailscale0 out on "${PI_INTERFACE}" to "${LAN_SUBNET}" \
  port 53 proto udp comment 'pi-gateway ts-subnet-dns-udp'
sudo ufw route allow in on tailscale0 out on "${PI_INTERFACE}" to "${LAN_SUBNET}" \
  port 53 proto tcp comment 'pi-gateway ts-subnet-dns-tcp'
sudo ufw route allow in on tailscale0 out on "${PI_INTERFACE}" to "${LAN_SUBNET}" \
  port 80 proto tcp comment 'pi-gateway ts-subnet-http'
sudo ufw route allow in on tailscale0 out on "${PI_INTERFACE}" to "${LAN_SUBNET}" \
  port 443 proto tcp comment 'pi-gateway ts-subnet-https'
TS_IP="$(tailscale ip -4 2>/dev/null | head -1)"
log "Subnet route reklam: ${LAN_SUBNET}"
# Pi MagicDNS/global NS kendini cözmesin — AdGuard 127.0.0.1 kalsin.
sudo tailscale set --advertise-routes="${LAN_SUBNET}" --accept-routes=false --accept-dns=false
log "Tamamlandi"
log ""
log "=== Senin yapman gereken (bir kez, tarayici) ==="
log "ONCESI: UFW tailscale0 :53/udp + ACL tag:pi-gateway:53 + Mac/telefon:"
log "        dig @${TS_IP} doubleclick.net    (0.0.0.0 / NXDOMAIN)"
log "        Pi uzerinde dig @${TS_IP} UFW yolunu dogrulamaz."
log "1) https://login.tailscale.com/admin/dns"
log "   Global nameserver: ${TS_IP}   (LAN ${LAN_SUBNET%%/*} DEGIL — INPUT 100.x kaynagi LAN kurali tutmaz)"
log "   Split DNS ${LAN_DOMAIN} -> ${TS_IP} kalsin (Override kapali cihaz)."
log "   Ikinci global NS ekleme (Tailscale paralel sorar, reklam kacar)."
log "   Override DNS servers: UFW+ACL+uzak dig yesil SONRA ac."
log "2) https://login.tailscale.com/admin/machines"
log "   pi-gateway -> tag:pi-gateway; route ${LAN_SUBNET} ONAYLA"
log "   Telefon/Mac: group:owners (tagsiz) veya tag:owner-device"
log "3) Telefon/Mac: Tailscale Connected + Use Tailscale DNS. Private DNS / iCloud Relay / Chrome Secure DNS kapali."
log ""
log "Panel ayni: http://${TS_IP}/  (MagicDNS sart degil). Filtre icin TS DNS sart."
