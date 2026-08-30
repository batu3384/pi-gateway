#!/usr/bin/env bash
# Tailscale admin DNS: global NS = Pi 100.x + Override. ACL ayri (setup-tailscale-acl.sh).
# Gerektirir: TAILSCALE_API_KEY (admin Keys → API access token). Device AUTHKEY yetmez.
set -euo pipefail
export LC_ALL=C
REMOTE_DIR="${REMOTE_DIR:-/home/${USER}/pi-gateway}"
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
_PG_ENV_LIB="${SCRIPT_DIR}/../lib/env-file.sh"
PG_SCRIPT_NAME="$(basename "$0")"
# shellcheck source=../lib/env-file.sh
source "${_PG_ENV_LIB:?}"
read_remote_dotenv || { echo "[${PG_SCRIPT_NAME}] HATA: .env" >&2; exit 1; }
log() { echo "[tailscale-dns] $*"; }
API_KEY="${TAILSCALE_API_KEY:-}"
LAN_DOMAIN="${LAN_DOMAIN:-home}"
API_AUTH_FILE=""
cleanup() {
  [[ -z "$API_AUTH_FILE" ]] || rm -f "$API_AUTH_FILE"
}
trap cleanup EXIT
command -v tailscale >/dev/null 2>&1 || { log "tailscale yok"; exit 1; }
if ! tailscale status --json 2>/dev/null | python3 -c \
  "import json,sys; sys.exit(0 if json.load(sys.stdin).get('BackendState')=='Running' else 1)"; then
  log "HATA: Tailscale bagli degil"
  exit 1
fi
TS_IP="$(tailscale ip -4 2>/dev/null | head -1)"
[[ "$TS_IP" == 100.* ]] || { log "HATA: Tailscale IPv4 yok ($TS_IP)"; exit 1; }
sudo tailscale set --accept-dns=false 2>/dev/null || true
if [[ -z "$API_KEY" || "$API_KEY" != tskey-api-* ]]; then
  log "HATA: TAILSCALE_API_KEY yok (tskey-api-…)."
  log "Bir kez: https://login.tailscale.com/admin/settings/keys → Generate API key"
  exit 1
fi
API_AUTH_FILE="$(mktemp)"
chmod 600 "$API_AUTH_FILE"
printf 'user = "%s:"\n' "$API_KEY" >"$API_AUTH_FILE"
# '-' = API key sahibinin default tailnet (email kesme 404)
BASE="https://api.tailscale.com/api/v2/tailnet/-"
body="$(python3 -c "
import json
ts='${TS_IP}'
domain='${LAN_DOMAIN}'
print(json.dumps({
  'nameservers':[{'address': ts, 'useWithExitNode': True}],
  'preferences':{'overrideLocalDNS': True, 'magicDNS': True},
  'splitDNS':{domain:[{'address': ts}]},
}))
")"
log "DNS yaziliyor (NS=$TS_IP Override=on split=${LAN_DOMAIN})..."
resp="$(curl --config "$API_AUTH_FILE" -fsS -X POST "${BASE}/dns/configuration" \
  -H "Content-Type: application/json" \
  -d "$body")"
printf '%s\n' "$resp" | python3 -c "
import json,sys
d=json.load(sys.stdin)
ns=[(x.get('address') if isinstance(x,dict) else x) for x in (d.get('nameservers') or [])]
pref=d.get('preferences') or {}
print('[tailscale-dns] nameservers=', ns)
print('[tailscale-dns] overrideLocalDNS=', pref.get('overrideLocalDNS'))
print('[tailscale-dns] magicDNS=', pref.get('magicDNS'))
want='${TS_IP}'
if want not in ns:
    raise SystemExit('NS dogrulanamadi')
if pref.get('overrideLocalDNS') is not True:
    raise SystemExit('Override acik degil')
"
log "Tamam — Mac/telefon Use Tailscale DNS acik; Pi accept-dns=false."
log "Kanit: dig @${TS_IP} doubleclick.net +short"

# Pi tag:pi-gateway yoksa ACL dst :53 hic eslesmez (Override = internet olumu).
self_id="$(tailscale status --json 2>/dev/null | python3 -c "
import json,sys
d=json.load(sys.stdin)
print((d.get('Self') or {}).get('ID') or '')
")"
if [[ -n "$self_id" ]]; then
  tags_json="$(curl --config "$API_AUTH_FILE" -fsS "https://api.tailscale.com/api/v2/device/${self_id}?fields=all" 2>/dev/null || true)"
  if printf '%s' "$tags_json" | python3 -c "import json,sys; t=json.load(sys.stdin).get('tags') or []; sys.exit(0 if 'tag:pi-gateway' in t else 1)" 2>/dev/null; then
    log "Pi tag:pi-gateway OK"
  else
    log "Pi tag:pi-gateway eksik — API ile ekleniyor"
    curl --config "$API_AUTH_FILE" -fsS -X POST "https://api.tailscale.com/api/v2/device/${self_id}/tags" \
      -H "Content-Type: application/json" \
      -d '{"tags":["tag:pi-gateway"]}' >/dev/null
    log "Pi tag:pi-gateway yazildi"
  fi
fi
