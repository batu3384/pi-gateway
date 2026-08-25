#!/usr/bin/env bash
# Tailscale Serve: gecerli HTTPS ile Caddy'ye proxy (*.home uzaktan)
set -euo pipefail
REMOTE_DIR="${REMOTE_DIR:-/home/${USER}/pi-gateway}"
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
_PG_ENV_LIB="${SCRIPT_DIR:-$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)}/../lib/env-file.sh"
PG_SCRIPT_NAME="$(basename "$0")"
# shellcheck source=../lib/env-file.sh
source "${_PG_ENV_LIB:?}"
read_remote_dotenv || { echo "[${PG_SCRIPT_NAME:-script}] HATA: .env dotenv parser hatasi" >&2; exit 1; }
LAN_DOMAIN="${LAN_DOMAIN:-home}"
PI_IP="${PI_STATIC_IP:-}"
ADGUARD_WEB_PORT="${ADGUARD_WEB_PORT:-8080}"
NETALERTX_PORT="${NETALERTX_PORT:-20211}"
NETALERTX_LISTEN_ADDR="${NETALERTX_LISTEN_ADDR:-172.17.0.1}"
CADDYFILE="${REMOTE_DIR}/config/caddy/Caddyfile"
MARKER="${REMOTE_DIR}/config/caddy/.tailscale-serve-block"
log() { echo "[tailscale-serve] $*"; }
command -v tailscale >/dev/null 2>&1 || { log "tailscale yok"; exit 0; }
if ! tailscale status --json 2>/dev/null | python3 -c \
  "import json,sys; sys.exit(0 if json.load(sys.stdin).get('BackendState')=='Running' else 1)"; then
  log "Tailscale bagli degil"
  exit 0
fi
TS_DNS="$(tailscale status --json 2>/dev/null | python3 -c "
import json,sys
print(json.load(sys.stdin).get('Self',{}).get('DNSName','').rstrip('.'))
")"
[[ -n "$TS_DNS" ]] || { log "HATA: Tailscale DNS adi alinamadi"; exit 1; }
log "Tailscale panel: https://${TS_DNS}"
# Caddy: path tabanli uzaktan erisim blogu
if [[ -f "$CADDYFILE" ]]; then
  python3 - "$CADDYFILE" "$MARKER" "$TS_DNS" "$LAN_DOMAIN" "$PI_IP" "$ADGUARD_WEB_PORT" "$NETALERTX_PORT" "$NETALERTX_LISTEN_ADDR" <<'PY'
import sys
from pathlib import Path
caddyfile, marker, ts_dns, domain, pi_ip, agh_port, nax_port, nax_host = sys.argv[1:9]
path = Path(caddyfile)
text = path.read_text()
start = f"# BEGIN TAILSCALE PANEL {ts_dns}"
end = f"# END TAILSCALE PANEL {ts_dns}"
# Tailscale Serve terminates TLS on 100.x:443, then HTTP → Caddy LAN :80.
# Site MUST be http:// (no tls) — otherwise Caddy 308→https loops through Serve.
# Caddy compose binds PI_STATIC_IP only (not 127.0.0.1).
block = f"""{start}
http://{ts_dns} {{
\t# no basic_auth — Tailscale ACL; Serve = HTTPS to phone
\thandle /p/status* {{
\t\turi strip_prefix /p/status
\t\treverse_proxy uptime-kuma:3001 {{
\t\t\theader_down Location / /p/status/
\t\t}}
\t}}
\thandle /p/logs* {{
\t\turi strip_prefix /p/logs
\t\treverse_proxy dozzle:8080 {{
\t\t\theader_down Location / /p/logs/
\t\t}}
\t}}
\thandle /p/dns* {{
\t\turi strip_prefix /p/dns
\t\treverse_proxy {pi_ip}:{agh_port} {{
\t\t\theader_down Location / /p/dns/
\t\t}}
\t}}
\thandle /p/n8n* {{
\t\turi strip_prefix /p/n8n
\t\treverse_proxy n8n:5678 {{
\t\t\theader_down Location / /p/n8n/
\t\t}}
\t}}
\thandle /p/devices* {{
\t\turi strip_prefix /p/devices
\t\treverse_proxy {nax_host}:{nax_port} {{
\t\t\theader_down Location / /p/devices/
\t\t}}
\t}}
\thandle /p/grafana* {{
\t\turi strip_prefix /p/grafana
\t\treverse_proxy grafana:3000 {{
\t\t\theader_down Location / /p/grafana/
\t\t}}
\t}}
\thandle {{
\t\treverse_proxy homepage:3000
\t}}
}}
{end}
"""
if start in text:
    pre, rest = text.split(start, 1)
    _, post = rest.split(end, 1)
    text = pre.rstrip() + "\n\n" + block + post.lstrip()
else:
    text = text.rstrip() + "\n\n" + block + "\n"
path.write_text(text)
Path(marker).write_text(f"{ts_dns}\n")
print(f"[tailscale-serve] Caddy blogu guncellendi: {ts_dns}")
PY
  docker exec caddy caddy reload --config /etc/caddy/Caddyfile 2>/dev/null \
    || docker restart caddy >/dev/null 2>&1 || true
fi
mkdir -p /var/lib/pi-gateway 2>/dev/null || sudo mkdir -p /var/lib/pi-gateway
echo "https://${TS_DNS}" | sudo tee /var/lib/pi-gateway/tailscale-panel-url >/dev/null 2>&1 || true
bash "$(dirname "$0")/setup-caddy-lan-ip.sh" || true

# Caddy compose binds PI_STATIC_IP:80 — Serve terminates TLS, proxies HTTP (no 308 loop)
[[ -n "$PI_IP" ]] || { log "HATA: PI_STATIC_IP bos — Serve hedefi yok"; exit 1; }
serve_target="http://${PI_IP}:80"
prev_serve="$(tailscale serve status 2>/dev/null || true)"
log "tailscale serve -> ${serve_target} (Caddy http://MagicDNS, TLS=Serve)"
if ! sudo tailscale serve --bg "$serve_target" 2>&1; then
  # --bg overwrite fail ederse reset+retry; basarisizsa onceki config kaybolmasin diye uyari
  sudo tailscale serve reset 2>/dev/null || true
  if ! sudo tailscale serve --bg "$serve_target" 2>&1; then
    log "HATA: Tailscale Serve baslatilamadi"
    if [[ -n "$prev_serve" && "$prev_serve" != *"No serve"* ]]; then
      log "WARN: onceki Serve config reset edilmis olabilir — elle: sudo tailscale serve --bg '${serve_target}'"
    fi
    log "Ac: https://login.tailscale.com/f/serve?node=$(tailscale status --json 2>/dev/null | python3 -c 'import json,sys; print(json.load(sys.stdin).get(\"Self\",{}).get(\"ID\",\"\"))' 2>/dev/null || echo '')"
    exit 0
  fi
fi
# Smoke via Tailscale IP (MagicDNS may not resolve on Pi itself)
ts_ip="$(tailscale ip -4 2>/dev/null | head -1 || true)"
code="000"
if [[ -n "$ts_ip" ]]; then
  code="$(curl -sk -o /dev/null -w '%{http_code}' --connect-timeout 5 \
    --resolve "${TS_DNS}:443:${ts_ip}" "https://${TS_DNS}/p/status/" 2>/dev/null || echo 000)"
fi
case "$code" in
  000|502|503) log "WARN: Serve smoke https://${TS_DNS}/p/status/ -> HTTP ${code}" ;;
  *) log "Serve smoke OK (HTTP ${code})" ;;
esac
log "Tamamlandi — uzaktan: https://${TS_DNS}/"
log "Paneller: /p/dns /p/status /p/logs /p/devices /p/grafana ..."
