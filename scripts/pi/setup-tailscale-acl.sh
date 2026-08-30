#!/usr/bin/env bash
# Tailscale ACL: yalnizca group:owners -> Pi ve ev LAN
set -euo pipefail
export LC_ALL=C
REMOTE_DIR="${REMOTE_DIR:-/home/${USER}/pi-gateway}"
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
_PG_ENV_LIB="${SCRIPT_DIR:-$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)}/../lib/env-file.sh"
PG_SCRIPT_NAME="$(basename "$0")"
# shellcheck source=../lib/env-file.sh
source "${_PG_ENV_LIB:?}"
read_remote_dotenv || { echo "[${PG_SCRIPT_NAME:-script}] HATA: .env dotenv parser hatasi" >&2; exit 1; }
ACL_LOCAL="${REMOTE_DIR}/config/tailscale/acl.hujson"
ACL_OWNER="${TAILSCALE_ACL_OWNER:-}"
ACL_LAN_SUBNET="${TAILSCALE_LAN_SUBNET:-${LAN_SUBNET_CIDR:-}}"
API_KEY="${TAILSCALE_API_KEY:-}"
ACL_APPLIED_MARKER="${TAILSCALE_ACL_APPLIED_MARKER:-/var/lib/pi-gateway/tailscale-acl-applied}"
API_AUTH_FILE=""
cleanup() {
  [[ -z "$API_AUTH_FILE" ]] || rm -f "$API_AUTH_FILE"
}
trap cleanup EXIT
log() { echo "[tailscale-acl] $*"; }
command -v tailscale >/dev/null 2>&1 || { log "tailscale yok"; exit 0; }
if [[ -z "$ACL_OWNER" || "$ACL_OWNER" == CHANGE_ME* ]]; then
  log "atlandi (TAILSCALE_ACL_OWNER yok/placeholder) — ACL publish edilmedi"
  exit 0
fi
if [[ ! "$ACL_OWNER" =~ ^[A-Za-z0-9._%+-]+@[A-Za-z0-9.-]+\.[A-Za-z]{2,}$ ]]; then
  log "WARN: TAILSCALE_ACL_OWNER gecersiz e-posta — ACL atlandi (duzelt: .env)"
  exit 0
fi
if [[ ! "$ACL_LAN_SUBNET" =~ ^([0-9]{1,3}\.){3}[0-9]{1,3}/[0-9]{1,2}$ ]]; then
  log "HATA: TAILSCALE_LAN_SUBNET veya LAN_SUBNET_CIDR gecersiz — broad ACL publish reddedildi"
  exit 1
fi
ACL_TEMPLATE="${ACL_TEMPLATE:-${REMOTE_DIR}/config/tailscale/acl.hujson.example}"
[[ -f "$ACL_TEMPLATE" ]] || { log "ACL sablonu yok: $ACL_TEMPLATE"; exit 1; }
mkdir -p "$(dirname "$ACL_LOCAL")"
python3 - "$ACL_TEMPLATE" "$ACL_LOCAL" "$ACL_OWNER" "$ACL_LAN_SUBNET" <<'PY'
import sys
import ipaddress
from pathlib import Path
template, out, owner, lan_subnet = sys.argv[1], sys.argv[2], sys.argv[3], sys.argv[4]
text = Path(template).read_text(encoding="utf-8")
placeholder = "YOUR_TAILSCALE_EMAIL@example.com"
if placeholder not in text:
    sys.exit("placeholder missing in ACL template")
try:
    lan_subnet = str(ipaddress.ip_network(lan_subnet, strict=False))
except ValueError as exc:
    sys.exit(f"invalid LAN subnet: {exc}")
text = text.replace(placeholder, owner).replace("YOUR_TAILSCALE_LAN_SUBNET", lan_subnet)
Path(out).write_text(text, encoding="utf-8")
PY
ACL_FILE="$ACL_LOCAL"
if [[ -n "$API_KEY" ]]; then
  API_AUTH_FILE="$(mktemp)"
  chmod 600 "$API_AUTH_FILE"
  printf 'user = "%s:"\n' "$API_KEY" >"$API_AUTH_FILE"
  tailnet="-"
  log "API ile gonderiliyor (tailnet: -)..."
  if curl --config "$API_AUTH_FILE" -fsS -X POST "https://api.tailscale.com/api/v2/tailnet/${tailnet}/acl" \
    -H "Content-Type: application/json" \
    --data-binary @"$ACL_FILE"; then
    sudo install -d -m 755 "$(dirname "$ACL_APPLIED_MARKER")"
    printf '%s\n' "$(date -Iseconds)" | sudo tee "$ACL_APPLIED_MARKER" >/dev/null
    log "ACL uygulandi"
    exit 0
  fi
  log "WARN: API basarisiz — manuel yapistir"
fi
log ""
log "=== Manuel (bir kez) ==="
log "1) https://login.tailscale.com/admin/acls"
log "2) Asagidaki dosyanin icerigini yapistir:"
log "   $ACL_FILE"
log "3) Save"
log ""
log "Sahip: $ACL_OWNER — Tailnet'teki diger hesaplar Pi'ye erisemez."
log "Not: Bu interneti kapatmaz; yalnizca Tailscale agindaki kimlerin erisebilecegini belirler."
