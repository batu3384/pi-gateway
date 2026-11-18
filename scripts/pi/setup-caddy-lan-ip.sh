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
ENABLE_N8N="${ENABLE_N8N:-false}"
STATE_OWNER="${PI_USER:-${SUDO_USER:-${USER:-pi}}}"
CADDYFILE="${REMOTE_DIR}/config/caddy/Caddyfile"
log() { echo "[caddy-lan-ip] $*"; }
[[ -f "$CADDYFILE" ]] || { log "Caddyfile yok — atlandi"; exit 0; }
[[ -n "$PI_IP" || -n "$TS_IP" ]] || { log "IP yok — atlandi"; exit 0; }
python3 - "$CADDYFILE" "$PI_IP" "$TS_IP" "$ADGUARD_WEB_PORT" "$NETALERTX_PORT" "$NETALERTX_LISTEN_ADDR" "$ENABLE_N8N" <<'PY'
import sys
from pathlib import Path
caddyfile, pi_ip, ts_ip, agh_port, nax_port, nax_host, enable_n8n = sys.argv[1:8]
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
    auth_line = (auth if with_auth and auth else "\t# no basic_auth — Tailscale loopback :8088 (LAN erisemez)")
    site_addr = f"http://{ip}" if with_auth else f"http://{ip}:8088"
    parts = [
        f"{site_addr} {{",
        auth_line,
        path_proxy("p/status", "gatus:8080"),
        path_proxy("p/logs", "dozzle:8080"),
        path_proxy("p/dns", f"{upstream}:{agh_port}"),
    ]
    if enable_n8n == "true":
        parts.append(path_proxy("p/n8n", "n8n:5678"))
    parts.extend([
        path_proxy("p/devices", f"{nax_host}:{nax_port}"),
        path_proxy("p/grafana", "grafana:3000"),
        "\thandle {",
        "\t\treverse_proxy glance:8080",
        "\t}",
        "}",
    ])
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

# Caddy Tailscale authless bloku yalniz 127.0.0.1:8088'te dinler — tailscale0 IP:80 -> 127.0.0.1:8088 DNAT
# Phone: Tailscale Connected yeter (MagicDNS / Use Tailscale DNS gerekmez; LAN 192.168.x erisemez)
ensure_ts80_dnat() {
  local ts_ip="$1" pi_ip="$2" marker="/var/lib/pi-gateway/ts80-dnat-ip" old="" target="127.0.0.1:8088"
  [[ "$ts_ip" == 100.* ]] || return 0
  sudo mkdir -p /var/lib/pi-gateway 2>/dev/null || true
  sudo chown "${STATE_OWNER}:${STATE_OWNER}" /var/lib/pi-gateway 2>/dev/null || true
  sudo /usr/sbin/sysctl -w net.ipv4.conf.all.route_localnet=0 >/dev/null 2>&1 || true
  sudo /usr/sbin/sysctl -w net.ipv4.conf.default.route_localnet=0 >/dev/null 2>&1 || true
  sudo /usr/sbin/sysctl -w net.ipv4.conf.tailscale0.route_localnet=1 >/dev/null 2>&1 || true
  if [[ -r "$marker" ]]; then
    old="$(cat "$marker" 2>/dev/null || true)"
  fi
  for old_ip in "$old" "$ts_ip"; do
    [[ -n "$old_ip" ]] || continue
    if [[ -n "$pi_ip" ]]; then
      sudo iptables -t nat -D PREROUTING -d "$old_ip" -p tcp --dport 80 -j DNAT --to-destination "${pi_ip}:80" 2>/dev/null || true
      sudo iptables -t nat -D PREROUTING -i tailscale0 -d "$old_ip" -p tcp --dport 80 -j DNAT --to-destination "${pi_ip}:80" 2>/dev/null || true
      sudo iptables -t nat -D OUTPUT -d "$old_ip" -p tcp --dport 80 -j DNAT --to-destination "${pi_ip}:80" 2>/dev/null || true
    fi
    sudo iptables -t nat -D PREROUTING -d "$old_ip" -p tcp --dport 80 -j DNAT --to-destination "$target" 2>/dev/null || true
    sudo iptables -t nat -D PREROUTING -i tailscale0 -d "$old_ip" -p tcp --dport 80 -j DNAT --to-destination "$target" 2>/dev/null || true
    sudo iptables -t nat -D OUTPUT -d "$old_ip" -p tcp --dport 80 -j DNAT --to-destination "$target" 2>/dev/null || true
  done
  sudo iptables -t nat -A PREROUTING -i tailscale0 -d "$ts_ip" -p tcp --dport 80 -j DNAT --to-destination "$target"
  sudo iptables -t nat -A OUTPUT -d "$ts_ip" -p tcp --dport 80 -j DNAT --to-destination "$target"
  if command -v ufw >/dev/null 2>&1; then
    local _num
    while true; do
      _num="$(sudo ufw status numbered 2>/dev/null | grep -F 'pi-gateway tailscale-8088' | sed -n 's/^[[:space:]]*\[[[:space:]]*\([0-9]*\)\].*/\1/p' | head -1 || true)"
      [[ -n "$_num" ]] || break
      sudo ufw --force delete "$_num" >/dev/null 2>&1 || break
    done
    sudo ufw allow in on tailscale0 to any port 8088 proto tcp comment 'pi-gateway tailscale-8088' >/dev/null 2>&1 || true
  fi
  printf '%s\n' "$ts_ip" | sudo tee "$marker" >/dev/null
  # reboot kaliciligi (varsa)
  if command -v netfilter-persistent >/dev/null 2>&1; then
    sudo netfilter-persistent save >/dev/null 2>&1 || true
  elif [[ -d /etc/iptables ]]; then
    sudo sh -c 'iptables-save > /etc/iptables/rules.v4' 2>/dev/null || true
  fi
  log "TS HTTP: http://${ts_ip}/p/... -> ${target} (tailscale0 loopback isolation)"
}
if [[ -n "$TS_IP" && -n "$PI_IP" ]]; then
  ensure_ts80_dnat "$TS_IP" "$PI_IP" || log "WARN: TS:80 DNAT basarisiz"
fi
log "Tamamlandi"
