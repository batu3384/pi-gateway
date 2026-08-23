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
  python3 - "$CADDYFILE" "$MARKER" "$TS_DNS" "$LAN_DOMAIN" "$PI_IP" "$ADGUARD_WEB_PORT" "$NETALERTX_PORT" <<'PY'
import sys
from pathlib import Path
caddyfile, marker, ts_dns, domain, pi_ip, agh_port, nax_port = sys.argv[1:8]
path = Path(caddyfile)
text = path.read_text()
start = f"# BEGIN TAILSCALE PANEL {ts_dns}"
end = f"# END TAILSCALE PANEL {ts_dns}"
# Tailscale Serve / MagicDNS: basic_auth YOK — Telegram Basic Auth acmaz; tailnet ACL yeter
# handle_path yerine strip+Location rewrite (uygulama /login redirect kirilmasin)
block = f"""{start}
{ts_dns} {{
\ttls /etc/caddy/certs/{domain}.pem /etc/caddy/certs/{domain}-key.pem
\t# no basic_auth — Tailscale ACL
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
\thandle /p/git* {{
\t\turi strip_prefix /p/git
\t\treverse_proxy forgejo:3000 {{
\t\t\theader_down Location / /p/git/
\t\t}}
\t}}
\thandle /p/sync* {{
\t\turi strip_prefix /p/sync
\t\treverse_proxy syncthing:8384 {{
\t\t\theader_down Location / /p/sync/
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
\t\treverse_proxy {pi_ip}:{nax_port} {{
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
# Gecerli Tailscale HTTPS -> Caddy (mkcert arada; telefon guvenilir sertifika gorur)
if tailscale serve status 2>/dev/null | grep -q "https"; then
  log "tailscale serve zaten aktif"
else
  log "tailscale serve baslatiliyor (https+insecure -> Caddy:443)"
  sudo tailscale serve reset 2>/dev/null || true
  if ! sudo tailscale serve --bg "https+insecure://127.0.0.1:443" 2>&1; then
    log "HATA: Tailscale Serve tailnet'te kapali"
    log "Ac: https://login.tailscale.com/f/serve?node=$(tailscale status --json 2>/dev/null | python3 -c 'import json,sys; print(json.load(sys.stdin).get(\"Self\",{}).get(\"ID\",\"\"))' 2>/dev/null || echo '')"
    log "Telegram uzaktan linkler http://$(tailscale ip -4 2>/dev/null | head -1)/p/... kullanacak (Serve sonrasi HTTPS)"
    bash "$(dirname "$0")/setup-caddy-lan-ip.sh" || true
    exit 0
  fi
fi
log "Tamamlandi — uzaktan: https://${TS_DNS}/"
log "Paneller: /p/dns /p/status /p/logs /p/devices ..."
