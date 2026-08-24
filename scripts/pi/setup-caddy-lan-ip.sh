#!/usr/bin/env bash
# Caddy: LAN + Tailscale IP uzerinden /p/* (DNS/mkcert gerekmez)
# Tailscale 100.x: basic_auth YOK (Telegram Basic Auth acmaz; ACL yeter)
# LAN 192.x: basic_auth VAR
# handle_path yerine strip+Location rewrite — uygulama redirect'leri kirilmasin
set -euo pipefail
REMOTE_DIR="${REMOTE_DIR:-/home/${USER}/pi-gateway}"
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
_PG_ENV_LIB="${SCRIPT_DIR:-$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)}/../lib/env-file.sh"
PG_SCRIPT_NAME="$(basename "$0")"
# shellcheck source=../lib/env-file.sh
source "${_PG_ENV_LIB:?}"
read_remote_dotenv || { echo "[${PG_SCRIPT_NAME:-script}] HATA: .env dotenv parser hatasi" >&2; exit 1; }
PI_IP="${PI_STATIC_IP:-}"
TS_IP=""
if command -v tailscale >/dev/null 2>&1; then
  TS_IP="$(tailscale ip -4 2>/dev/null | head -1 || true)"
fi
ADGUARD_WEB_PORT="${ADGUARD_WEB_PORT:-8080}"
NETALERTX_PORT="${NETALERTX_PORT:-20211}"
# NetAlertX host-network LISTEN_ADDR (compose) — not PI_STATIC_IP
NETALERTX_LISTEN_ADDR="${NETALERTX_LISTEN_ADDR:-172.17.0.1}"
CADDYFILE="${REMOTE_DIR}/config/caddy/Caddyfile"
log() { echo "[caddy-lan-ip] $*"; }
[[ -f "$CADDYFILE" ]] || { log "Caddyfile yok — atlandi"; exit 0; }
[[ -n "$PI_IP" || -n "$TS_IP" ]] || { log "IP yok — atlandi"; exit 0; }
python3 - "$CADDYFILE" "$PI_IP" "$TS_IP" "$ADGUARD_WEB_PORT" "$NETALERTX_PORT" "$NETALERTX_LISTEN_ADDR" <<'PY'
import sys
from pathlib import Path
caddyfile, pi_ip, ts_ip, agh_port, nax_port, nax_host = sys.argv[1:7]
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
        path_proxy("p/devices", f"{nax_host}:{nax_port}"),
        path_proxy("p/grafana", "grafana:3000"),
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
# Not: 8080/20211 tailscale0 allow artik setup-tailscale-panel-ports.sh
# (dogrudan :PORT — /p/ asset 404 yok). Eski strip loop silindi.
docker exec caddy caddy reload --config /etc/caddy/Caddyfile 2>/dev/null \
  || docker restart caddy >/dev/null 2>&1 || true

# Caddy compose binds only PI_STATIC_IP:80 — DNAT Tailscale IP:80 → LAN Caddy
# Phone: Tailscale Connected yeter (MagicDNS / Use Tailscale DNS gerekmez)
ensure_ts80_dnat() {
  local ts_ip="$1" pi_ip="$2" marker="/var/lib/pi-gateway/ts80-dnat-ip" old=""
  [[ "$ts_ip" == 100.* && -n "$pi_ip" ]] || return 0
  sudo mkdir -p /var/lib/pi-gateway 2>/dev/null || true
  if [[ -r "$marker" ]]; then
    old="$(cat "$marker" 2>/dev/null || true)"
  fi
  if [[ -n "$old" && "$old" != "$ts_ip" ]]; then
    sudo iptables -t nat -D PREROUTING -d "$old" -p tcp --dport 80 -j DNAT --to-destination "${pi_ip}:80" 2>/dev/null || true
    sudo iptables -t nat -D OUTPUT -d "$old" -p tcp --dport 80 -j DNAT --to-destination "${pi_ip}:80" 2>/dev/null || true
  fi
  sudo iptables -t nat -D PREROUTING -d "$ts_ip" -p tcp --dport 80 -j DNAT --to-destination "${pi_ip}:80" 2>/dev/null || true
  sudo iptables -t nat -D OUTPUT -d "$ts_ip" -p tcp --dport 80 -j DNAT --to-destination "${pi_ip}:80" 2>/dev/null || true
  sudo iptables -t nat -A PREROUTING -d "$ts_ip" -p tcp --dport 80 -j DNAT --to-destination "${pi_ip}:80"
  sudo iptables -t nat -A OUTPUT -d "$ts_ip" -p tcp --dport 80 -j DNAT --to-destination "${pi_ip}:80"
  printf '%s\n' "$ts_ip" | sudo tee "$marker" >/dev/null
  # reboot kaliciligi (varsa)
  if command -v netfilter-persistent >/dev/null 2>&1; then
    sudo netfilter-persistent save >/dev/null 2>&1 || true
  elif [[ -d /etc/iptables ]]; then
    sudo sh -c 'iptables-save > /etc/iptables/rules.v4' 2>/dev/null || true
  fi
  log "TS HTTP: http://${ts_ip}/p/... -> ${pi_ip}:80 (DNS yok)"
}
if [[ -n "$TS_IP" && -n "$PI_IP" ]]; then
  ensure_ts80_dnat "$TS_IP" "$PI_IP" || log "WARN: TS:80 DNAT basarisiz"
fi
log "Tamamlandi"
