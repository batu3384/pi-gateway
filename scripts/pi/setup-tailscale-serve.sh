#!/usr/bin/env bash
# Tailscale Serve: gecerli HTTPS ile Caddy'ye proxy (*.home uzaktan)
set -euo pipefail

REMOTE_DIR="${REMOTE_DIR:-/home/${USER}/pi-gateway}"
# shellcheck source=/dev/null
[[ -f "$REMOTE_DIR/.env" ]] && source "$REMOTE_DIR/.env"

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

block = f"""{start}
{ts_dns} {{
\ttls /etc/caddy/certs/{domain}.pem /etc/caddy/certs/{domain}-key.pem
\t__CADDY_BASIC_AUTH_PLACEHOLDER__
\thandle_path /p/status* {{
\t\treverse_proxy uptime-kuma:3001
\t}}
\thandle_path /p/logs* {{
\t\treverse_proxy dozzle:8080
\t}}
\thandle_path /p/dns* {{
\t\treverse_proxy {pi_ip}:{agh_port}
\t}}
\thandle_path /p/git* {{
\t\treverse_proxy forgejo:3000
\t}}
\thandle_path /p/sync* {{
\t\treverse_proxy syncthing:8384
\t}}
\thandle_path /p/n8n* {{
\t\treverse_proxy n8n:5678
\t}}
\thandle_path /p/devices* {{
\t\treverse_proxy {pi_ip}:{nax_port} {{
\t\t\theader_up X-Forwarded-Proto {{scheme}}
\t\t\theader_up X-Forwarded-Host {{host}}
\t\t}}
\t}}
\thandle {{
\t\treverse_proxy homepage:3000
\t}}
}}
{end}
"""

# Auth blogunu mevcut Caddyfile'dan kopyala
auth = ""
for line in text.splitlines():
    if line.strip().startswith("basic_auth {"):
        auth_lines = [line]
        for inner in text.splitlines()[text.splitlines().index(line) + 1:]:
            auth_lines.append(inner)
            if inner.strip() == "}":
                break
        auth = "\n".join(auth_lines)
        break
block = block.replace("\t__CADDY_BASIC_AUTH_PLACEHOLDER__", auth or "\t# basic_auth yok")

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

# Gecerli Tailscale HTTPS -> Caddy (mkcert arada; telefon guvenilir sertifika gorur)
if tailscale serve status 2>/dev/null | grep -q "https"; then
  log "tailscale serve zaten aktif"
else
  log "tailscale serve baslatiliyor (https+insecure -> Caddy:443)"
  sudo tailscale serve reset 2>/dev/null || true
  if ! sudo tailscale serve --bg "https+insecure://127.0.0.1:443" 2>&1; then
    log "HATA: Tailscale Serve tailnet'te kapali"
    log "Ac: https://login.tailscale.com/admin/acls (veya script ciktisindaki /f/serve linki)"
    log "Sonra tekrar: bash scripts/pi/setup-tailscale-serve.sh"
    exit 0
  fi
fi

log "Tamamlandi — uzaktan: https://${TS_DNS}/"
log "Paneller: /p/dns /p/status /p/logs /p/devices ..."
