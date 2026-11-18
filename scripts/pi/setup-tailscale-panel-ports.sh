#!/usr/bin/env bash
# Tailscale IP uzerinden panel portlari (yalniz TS_PANEL_DIRECT_PORTS=true ve ACL kaniti varsa).
# Varsayilan TS_PANEL_DIRECT_PORTS=false: tum eski DNAT, UFW ve route_localnet ayarlari temizlenir.
set -euo pipefail
REMOTE_DIR="${REMOTE_DIR:-/home/${USER}/pi-gateway}"
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
_PG_ENV_LIB="${SCRIPT_DIR}/../lib/env-file.sh"
PG_SCRIPT_NAME="$(basename "$0")"
# shellcheck source=../lib/env-file.sh
source "${_PG_ENV_LIB:?}"
read_remote_dotenv || { echo "[${PG_SCRIPT_NAME}] HATA: .env dotenv parser hatasi" >&2; exit 1; }

log() { echo "[ts-panel-ports] $*"; }

TS_PANEL_DIRECT_PORTS="${TS_PANEL_DIRECT_PORTS:-false}"
if [[ "$TS_PANEL_DIRECT_PORTS" != "true" ]]; then
  log "TS_PANEL_DIRECT_PORTS!=true — eski :PORT DNAT kurallari temizlenecek"
else
  log "WARN: :PORT erisim Caddy basic_auth bypass — tailnet ACL siki olmali (docs/TAILSCALE.md)"
fi
ACL_APPLIED_MARKER="${TAILSCALE_ACL_APPLIED_MARKER:-/var/lib/pi-gateway/tailscale-acl-applied}"
if [[ "$TS_PANEL_DIRECT_PORTS" == "true" \
  && "${TS_SERVE_REQUIRE_ACL:-true}" == "true" \
  && "${TS_SERVE_ALLOW_UNVERIFIED_ACL:-false}" != "true" \
  && ! -f "$ACL_APPLIED_MARKER" ]]; then
  log "ACL uygulama kaniti yok — direct panel portlari kapatiliyor"
  TS_PANEL_DIRECT_PORTS=false
fi

TS_IP=""
wait_ts() {
  for _ in $(seq 1 30); do
    if command -v tailscale >/dev/null 2>&1; then
      TS_IP="$(tailscale ip -4 2>/dev/null | head -1 || true)"
      [[ "$TS_IP" == 100.* ]] && return 0
    fi
    sleep 2
  done
  return 1
}
if command -v tailscale >/dev/null 2>&1; then
  TS_IP="$(tailscale ip -4 2>/dev/null | head -1 || true)"
fi
if [[ "$TS_IP" != 100.* ]]; then
  if [[ "${PI_GATEWAY_TS_PANEL_REQUIRE:-0}" == "1" && "$TS_PANEL_DIRECT_PORTS" == "true" ]]; then
    log "Tailscale IP yok — bekleniyor…"
    wait_ts || { log "HATA: Tailscale IP yok"; exit 1; }
  else
    log "Tailscale IP yok veya direct port kapali — atlandi"
    exit 0
  fi
fi

PI_IP="${PI_STATIC_IP:-}"
MARKER_DIR="/var/lib/pi-gateway"
MARKER="${MARKER_DIR}/ts-panel-ports.list"
_state_owner="${PI_USER:-${SUDO_USER:-${USER:-pi}}}"
sudo mkdir -p "$MARKER_DIR"
sudo chown "${_state_owner}:${_state_owner}" "$MARKER_DIR" 2>/dev/null || true
sudo chmod 775 "$MARKER_DIR" 2>/dev/null || true

clear_old() {
  local line hostport dest old_ts
  if [[ -f "$MARKER" && -n "$TS_IP" ]]; then
    while IFS= read -r line || [[ -n "$line" ]]; do
      [[ "$line" == *:* ]] || continue
      hostport="${line%% *}"
      dest="${line#* }"
      sudo iptables -t nat -D PREROUTING -d "$TS_IP" -p tcp --dport "${hostport}" -j DNAT --to-destination "$dest" 2>/dev/null || true
      sudo iptables -t nat -D PREROUTING -i tailscale0 -d "$TS_IP" -p tcp --dport "${hostport}" -j DNAT --to-destination "$dest" 2>/dev/null || true
      sudo iptables -t nat -D OUTPUT -d "$TS_IP" -p tcp --dport "${hostport}" -j DNAT --to-destination "$dest" 2>/dev/null || true
    done <"$MARKER"
  fi
  if [[ -f "${MARKER}.tsip" ]]; then
    old_ts="$(cat "${MARKER}.tsip" 2>/dev/null || true)"
    if [[ -n "$old_ts" && "$old_ts" != "$TS_IP" && -f "$MARKER" ]]; then
      while IFS= read -r line || [[ -n "$line" ]]; do
        [[ "$line" == *:* ]] || continue
        hostport="${line%% *}"
        dest="${line#* }"
        sudo iptables -t nat -D PREROUTING -d "$old_ts" -p tcp --dport "${hostport}" -j DNAT --to-destination "$dest" 2>/dev/null || true
        sudo iptables -t nat -D PREROUTING -i tailscale0 -d "$old_ts" -p tcp --dport "${hostport}" -j DNAT --to-destination "$dest" 2>/dev/null || true
        sudo iptables -t nat -D OUTPUT -d "$old_ts" -p tcp --dport "${hostport}" -j DNAT --to-destination "$dest" 2>/dev/null || true
      done <"$MARKER"
    fi
  fi
}

clear_ufw_direct_ports() {
  command -v ufw >/dev/null 2>&1 || return 0
  local nums n
  nums="$(sudo ufw status numbered 2>/dev/null | grep -E 'pi-gateway ts-panel-' | sed -E 's/^\[ *([0-9]+)\].*/\1/' | sort -rn || true)"
  for n in $nums; do
    [[ -n "$n" ]] && sudo ufw --force delete "$n" >/dev/null 2>&1 || true
  done
}

apply_one() {
  local hostport="$1" dest="$2"
  sudo iptables -t nat -D PREROUTING -d "$TS_IP" -p tcp --dport "$hostport" -j DNAT --to-destination "$dest" 2>/dev/null || true
  sudo iptables -t nat -D PREROUTING -i tailscale0 -d "$TS_IP" -p tcp --dport "$hostport" -j DNAT --to-destination "$dest" 2>/dev/null || true
  sudo iptables -t nat -D OUTPUT -d "$TS_IP" -p tcp --dport "$hostport" -j DNAT --to-destination "$dest" 2>/dev/null || true
  sudo iptables -t nat -A PREROUTING -i tailscale0 -d "$TS_IP" -p tcp --dport "$hostport" -j DNAT --to-destination "$dest"
  sudo iptables -t nat -A OUTPUT -d "$TS_IP" -p tcp --dport "$hostport" -j DNAT --to-destination "$dest"
}

clear_old
if [[ "$TS_PANEL_DIRECT_PORTS" != "true" ]]; then
  sudo rm -f "$MARKER" "${MARKER}.tsip" /etc/sysctl.d/99-pi-gateway-ts-panel.conf
  sudo /usr/sbin/sysctl -w net.ipv4.conf.all.route_localnet=0 >/dev/null 2>&1 || true
  sudo /usr/sbin/sysctl -w net.ipv4.conf.default.route_localnet=0 >/dev/null 2>&1 || true
  if [[ ! -s /var/lib/pi-gateway/ts80-dnat-ip ]]; then
    sudo /usr/sbin/sysctl -w "net.ipv4.conf.tailscale0.route_localnet=0" >/dev/null 2>&1 || true
  fi
  clear_ufw_direct_ports
  log "Direct panel portlari kapali — Caddy/Serve kullan (route_localnet=0)"
  exit 0
fi

# Yalniz tailscale0 arayuzunde route_localnet ac (LAN arayuzlerinde 127.0.0.0/8 spoof acilmaz)
sudo tee /etc/sysctl.d/99-pi-gateway-ts-panel.conf >/dev/null <<'SYSCTL'
net.ipv4.conf.tailscale0.route_localnet=1
SYSCTL
sudo /usr/sbin/sysctl -w net.ipv4.conf.all.route_localnet=0 >/dev/null 2>&1 || true
sudo /usr/sbin/sysctl -w "net.ipv4.conf.tailscale0.route_localnet=1" >/dev/null 2>&1 || true

PORT_MAP=(
  "gateway:3040:127.0.0.1:3040"
  "status:${GATUS_PORT:-3001}:127.0.0.1:${GATUS_PORT:-3001}"
  "logs:${DOZZLE_PORT:-9999}:127.0.0.1:${DOZZLE_PORT:-9999}"
  "dns:${ADGUARD_WEB_PORT:-8080}:127.0.0.1:${ADGUARD_WEB_PORT:-8080}"
  "grafana:${GRAFANA_PORT:-3030}:127.0.0.1:${GRAFANA_PORT:-3030}"
  "devices:${NETALERTX_PORT:-20211}:${NETALERTX_LISTEN_ADDR:-172.17.0.1}:${NETALERTX_PORT:-20211}"
)
if [[ "${ENABLE_N8N:-false}" == "true" ]]; then
  PORT_MAP+=("n8n:${N8N_PORT:-5678}:127.0.0.1:${N8N_PORT:-5678}")
fi

tmp="$(mktemp)"
ports_ufw=()
for entry in "${PORT_MAP[@]}"; do
  IFS=':' read -r _name hostport dest_ip dest_port <<<"$entry"
  [[ -n "$hostport" && -n "$dest_ip" && -n "$dest_port" ]] || continue
  dest="${dest_ip}:${dest_port}"
  apply_one "$hostport" "$dest"
  echo "${hostport} ${dest}" >>"$tmp"
  ports_ufw+=("$hostport")
  log "http://${TS_IP}:${hostport} -> ${dest} (${_name})"
done
if [[ -n "$PI_IP" ]]; then
  apply_one "80" "127.0.0.1:8088"
  echo "80 127.0.0.1:8088" >>"$tmp"
  log "http://${TS_IP}/ -> 127.0.0.1:8088 (glance)"
fi
sudo install -m 0644 "$tmp" "$MARKER"
rm -f "$tmp"
printf '%s\n' "$TS_IP" | sudo tee "${MARKER}.tsip" >/dev/null

if command -v ufw >/dev/null 2>&1; then
  clear_ufw_direct_ports
  for p in "${ports_ufw[@]}"; do
    sudo ufw allow in on tailscale0 to any port "$p" proto tcp comment "pi-gateway ts-panel-$p" >/dev/null 2>&1 || true
  done
fi

if command -v netfilter-persistent >/dev/null 2>&1; then
  sudo netfilter-persistent save >/dev/null 2>&1 || true
elif [[ -d /etc/iptables ]]; then
  sudo sh -c 'iptables-save > /etc/iptables/rules.v4' 2>/dev/null || true
fi

log "Tamamlandi — Telegram butonlari http://${TS_IP}:PORT"
