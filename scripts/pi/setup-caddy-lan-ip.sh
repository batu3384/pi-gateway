#!/usr/bin/env bash
# Caddy: LAN + Tailscale IP uzerinden /p/* (DNS/mkcert gerekmez)
# Tailscale 100.x: basic_auth YOK (Telegram Basic Auth acmaz; ACL yeter)
# LAN 192.x: basic_auth VAR
# handle_path yerine strip+Location rewrite — uygulama redirect'leri kirilmasin
set -euo pipefail

REMOTE_DIR="${REMOTE_DIR:-/home/${USER}/pi-gateway}"
# shellcheck source=/dev/null
[[ -f "$REMOTE_DIR/.env" ]] && source "$REMOTE_DIR/.env"

PI_IP="${PI_STATIC_IP:-}"
TS_IP=""
if command -v tailscale >/dev/null 2>&1; then
  TS_IP="$(tailscale ip -4 2>/dev/null | head -1 || true)"
fi
ADGUARD_WEB_PORT="${ADGUARD_WEB_PORT:-8080}"
NETALERTX_PORT="${NETALERTX_PORT:-20211}"
CADDYFILE="${REMOTE_DIR}/config/caddy/Caddyfile"

log() { echo "[caddy-lan-ip] $*"; }

[[ -f "$CADDYFILE" ]] || { log "Caddyfile yok — atlandi"; exit 0; }
[[ -n "$PI_IP" || -n "$TS_IP" ]] || { log "IP yok — atlandi"; exit 0; }

python3 - "$CADDYFILE" "$PI_IP" "$TS_IP" "$ADGUARD_WEB_PORT" "$NETALERTX_PORT" <<'PY'
import sys
from pathlib import Path

caddyfile, pi_ip, ts_ip, agh_port, nax_port = sys.argv[1:6]
path = Path(caddyfile)
text = path.read_text()
start = "# BEGIN DIRECT IP PANELS"
end = "# END DIRECT IP PANELS"
upstream = pi_ip or ts_ip


def is_tailscale_ip(ip: str) -> bool:
    return ip.startswith("100.")


def path_proxy(prefix: str, backend: str) -> str:
    # strip prefix; rewrite root-relative Location. Absolute https://… redirects
    # may still escape /p/ — apps that emit absolute URLs need app-level root_url.
    return f"""\thandle /{prefix}* {{
\t\turi strip_prefix /{prefix}
\t\treverse_proxy {backend} {{
\t\t\theader_down Location / /{prefix}/
\t\t}}
\t}}"""


def panel_block(ip: str, with_auth: bool, auth: str) -> str:
    auth_line = (auth if with_auth and auth else "\t# no basic_auth — Tailscale ACL / Telegram")
    parts = [
        f"http://{ip} {{",
        auth_line,
        path_proxy("p/status", "uptime-kuma:3001"),
        path_proxy("p/logs", "dozzle:8080"),
        path_proxy("p/dns", f"{upstream}:{agh_port}"),
        path_proxy("p/git", "forgejo:3000"),
        path_proxy("p/sync", "syncthing:8384"),
        path_proxy("p/n8n", "n8n:5678"),
        path_proxy("p/devices", f"{upstream}:{nax_port}"),
        "\thandle {",
        "\t\treverse_proxy homepage:3000",
        "\t}",
        "}",
    ]
    return "\n".join(parts)


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

ips = []
if pi_ip:
    ips.append(pi_ip)
if ts_ip and ts_ip not in ips:
    ips.append(ts_ip)

blocks = []
for ip in ips:
    with_auth = not is_tailscale_ip(ip)
    blocks.append(panel_block(ip, with_auth, auth))

section = start + "\n" + "\n\n".join(blocks) + "\n" + end

if "# BEGIN LAN IP PANEL" in text:
    pre, rest = text.split("# BEGIN LAN IP PANEL", 1)
    _, post = rest.split("# END LAN IP PANEL", 1)
    text = pre.rstrip() + "\n\n" + post.lstrip()

if start in text:
    pre, rest = text.split(start, 1)
    _, post = rest.split(end, 1)
    text = pre.rstrip() + "\n\n" + section + "\n" + post.lstrip()
else:
    text = text.rstrip() + "\n\n" + section + "\n"

path.write_text(text)
for ip in ips:
    mode = "auth" if not is_tailscale_ip(ip) else "no-auth"
    print(f"[caddy-lan-ip] http://{ip}/p/... ({mode})")
PY

# Dogrudan :8080/:20211 tailscale0 kapat — sadece Caddy 80/443
if command -v ufw >/dev/null 2>&1; then
  while true; do
    line="$(sudo ufw status numbered 2>/dev/null | grep -E '([0-9]+)/(tcp|udp) on tailscale0.*(8080|20211)|#( pi-gateway )?tailscale-(8080|20211)' | head -1 || true)"
    [[ -n "$line" ]] || break
    num="$(printf '%s\n' "$line" | sed -n 's/^[[:space:]]*\[\([0-9]*\)\].*/\1/p')"
    [[ -n "$num" ]] || break
    if ! echo y | sudo ufw delete "$num" >/dev/null 2>&1; then
      sudo ufw --force delete "$num" >/dev/null 2>&1 || break
    fi
  done
fi

docker exec caddy caddy reload --config /etc/caddy/Caddyfile 2>/dev/null \
  || docker restart caddy >/dev/null 2>&1 || true
log "Tamamlandi"
