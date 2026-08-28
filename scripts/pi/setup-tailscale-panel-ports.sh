#!/usr/bin/env bash
# Tailscale IP uzerinden panel portlari (path /p/ YOK — asset 404 olmaz).
# Telefon: Tailscale Connected yeter (MagicDNS gerekmez).
# DNAT: 100.x:PORT -> 127.0.0.1:PORT (veya AdGuard/NetAlertX host bind).
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
  if [[ "${PI_GATEWAY_TS_PANEL_REQUIRE:-0}" == "1" ]]; then
    log "Tailscale IP yok — bekleniyor…"
    wait_ts || { log "HATA: Tailscale IP yok"; exit 1; }
  else
    log "Tailscale IP yok — atlandi"
    exit 0
  fi
fi

PI_IP="${PI_STATIC_IP:-}"
# Docker 127.0.0.1 bind + DNAT from tailscale0 needs route_localnet
sudo tee /etc/sysctl.d/99-pi-gateway-ts-panel.conf >/dev/null <<'SYSCTL'
net.ipv4.conf.all.route_localnet=1
net.ipv4.conf.default.route_localnet=1
SYSCTL
sudo sysctl -w net.ipv4.conf.all.route_localnet=1 >/dev/null
sudo sysctl -w "net.ipv4.conf.tailscale0.route_localnet=1" >/dev/null 2>&1 || true

# name:hostPort:destIp:destPort
# dest 127.0.0.1 = compose localhost bind; AdGuard host *; NetAlertX docker0
mapfile -t PORT_MAP < <(cat <<EOF
status:3001:127.0.0.1:3001
logs:${DOZZLE_PORT:-9999}:127.0.0.1:${DOZZLE_PORT:-9999}
dns:${ADGUARD_WEB_PORT:-8080}:127.0.0.1:${ADGUARD_WEB_PORT:-8080}
n8n:${N8N_PORT:-5678}:127.0.0.1:${N8N_PORT:-5678}
grafana:${GRAFANA_PORT:-3030}:127.0.0.1:${GRAFANA_PORT:-3030}
devices:${NETALERTX_PORT:-20211}:${NETALERTX_LISTEN_ADDR:-172.17.0.1}:${NETALERTX_PORT:-20211}
EOF
)

MARKER_DIR="/var/lib/pi-gateway"
MARKER="${MARKER_DIR}/ts-panel-ports.list"
sudo mkdir -p "$MARKER_DIR"

clear_old() {
  local line hostport dest
  if [[ -f "$MARKER" ]]; then
    while IFS= read -r line || [[ -n "$line" ]]; do
      [[ "$line" == *:* ]] || continue
      hostport="${line%% *}"
      dest="${line#* }"
      sudo iptables -t nat -D PREROUTING -d "$TS_IP" -p tcp --dport "${hostport}" -j DNAT --to-destination "$dest" 2>/dev/null || true
      sudo iptables -t nat -D OUTPUT -d "$TS_IP" -p tcp --dport "${hostport}" -j DNAT --to-destination "$dest" 2>/dev/null || true
    done <"$MARKER"
  fi
  # also clear previous TS IP if changed
  if [[ -f "${MARKER}.tsip" ]]; then
    old_ts="$(cat "${MARKER}.tsip" 2>/dev/null || true)"
    if [[ -n "$old_ts" && "$old_ts" != "$TS_IP" && -f "$MARKER" ]]; then
      while IFS= read -r line || [[ -n "$line" ]]; do
        [[ "$line" == *:* ]] || continue
        hostport="${line%% *}"
        dest="${line#* }"
        sudo iptables -t nat -D PREROUTING -d "$old_ts" -p tcp --dport "${hostport}" -j DNAT --to-destination "$dest" 2>/dev/null || true
        sudo iptables -t nat -D OUTPUT -d "$old_ts" -p tcp --dport "${hostport}" -j DNAT --to-destination "$dest" 2>/dev/null || true
      done <"$MARKER"
    fi
  fi
}

apply_one() {
  local hostport="$1" dest="$2"
  sudo iptables -t nat -D PREROUTING -d "$TS_IP" -p tcp --dport "$hostport" -j DNAT --to-destination "$dest" 2>/dev/null || true
  sudo iptables -t nat -D OUTPUT -d "$TS_IP" -p tcp --dport "$hostport" -j DNAT --to-destination "$dest" 2>/dev/null || true
  sudo iptables -t nat -A PREROUTING -d "$TS_IP" -p tcp --dport "$hostport" -j DNAT --to-destination "$dest"
  sudo iptables -t nat -A OUTPUT -d "$TS_IP" -p tcp --dport "$hostport" -j DNAT --to-destination "$dest"
}

clear_old
if [[ "$TS_PANEL_DIRECT_PORTS" != "true" ]]; then
  sudo rm -f "$MARKER" "${MARKER}.tsip"
  log "Direct panel portlari kapali — Caddy/Serve kullan"
  exit 0
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
# also keep :80 -> Caddy LAN (homepage / optional /p)
if [[ -n "$PI_IP" ]]; then
  apply_one "80" "${PI_IP}:80"
  echo "80 ${PI_IP}:80" >>"$tmp"
  log "http://${TS_IP}/ -> ${PI_IP}:80 (homepage)"
fi
sudo install -m 0644 "$tmp" "$MARKER"
rm -f "$tmp"
printf '%s\n' "$TS_IP" | sudo tee "${MARKER}.tsip" >/dev/null

if command -v ufw >/dev/null 2>&1; then
  for p in "${ports_ufw[@]}"; do
    sudo ufw allow in on tailscale0 to any port "$p" proto tcp comment "pi-gateway ts-panel-$p" >/dev/null 2>&1 || true
  done
fi

if command -v netfilter-persistent >/dev/null 2>&1; then
  sudo netfilter-persistent save >/dev/null 2>&1 || true
elif [[ -d /etc/iptables ]]; then
  sudo sh -c 'iptables-save > /etc/iptables/rules.v4' 2>/dev/null || true
fi

log "Tamamlandi — Telegram butonlari http://${TS_IP}:PORT (path yok)"
