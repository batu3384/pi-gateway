#!/usr/bin/env bash
# Render edilmis config + .env dosyalarini Pi'ye gonderir
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=../lib/common.sh
source "$SCRIPT_DIR/../lib/common.sh"
load_env

PI_USER="${PI_USER:-pi}"
PI_HOST="${PI_DEPLOY_HOST:-${PI_STATIC_IP:-${PI_HOST:-}}}"
REMOTE_DIR="${REMOTE_DIR:-/home/$PI_USER/pi-gateway}"

[[ -n "$PI_HOST" ]] || die "PI_STATIC_IP gerekli"

log "Rendered configs -> ${PI_USER}@${PI_HOST}"

scp "$PROJECT_DIR/.env" "${PI_USER}@${PI_HOST}:/tmp/pi-gateway.env.new"
scp "$PROJECT_DIR/config/adguard/AdGuardHome.yaml" "${PI_USER}@${PI_HOST}:/tmp/AdGuardHome.yaml"
scp "$PROJECT_DIR/config/homepage/services.yaml" "${PI_USER}@${PI_HOST}:/tmp/homepage-services.yaml"
[[ -f "$PROJECT_DIR/config/caddy/Caddyfile" ]] && \
  scp "$PROJECT_DIR/config/caddy/Caddyfile" "${PI_USER}@${PI_HOST}:/tmp/Caddyfile" || true

ssh "${PI_USER}@${PI_HOST}" "REMOTE_DIR='${REMOTE_DIR}' PI_USER='${PI_USER}' bash -s" <<'REMOTE'
set -euo pipefail
R="${REMOTE_DIR:-/home/${PI_USER}/pi-gateway}"
NEW="/tmp/pi-gateway.env.new"
OLD="${R}/.env"
PRESERVE='N8N_ENCRYPTION_KEY CROWDSEC_BOUNCER_KEY CROWDSEC_API_KEY'
python3 - "$NEW" "$OLD" "$OLD" $PRESERVE <<'PY'
import sys
from pathlib import Path
new_path, old_path, out_path = Path(sys.argv[1]), Path(sys.argv[2]), Path(sys.argv[3])
preserve = set(sys.argv[4:])

def parse(path: Path):
    data = {}
    if not path.is_file():
        return data
    for line in path.read_text().splitlines():
        if not line or line.lstrip().startswith("#") or "=" not in line:
            continue
        k, _, v = line.partition("=")
        data[k.strip()] = v
    return data

new, old = parse(new_path), parse(old_path)
for k in preserve:
    ov = old.get(k, "").strip()
    nv = new.get(k, "").strip()
    if ov and (not nv or nv.startswith("CHANGE_ME") or nv.startswith("Degistir")):
        new[k] = old[k]
lines = new_path.read_text().splitlines() if new_path.is_file() else []
out_lines, seen = [], set()
for line in lines:
    if line and not line.lstrip().startswith("#") and "=" in line:
        k = line.partition("=")[0].strip()
        seen.add(k)
        out_lines.append(f"{k}={new[k]}")
        continue
    out_lines.append(line)
for k in preserve:
    if k in new and k not in seen:
        out_lines.append(f"{k}={new[k]}")
out_path.write_text("\n".join(out_lines) + "\n")
print("[env-merge] ok")
PY
rm -f "$NEW"
sudo chown "${PI_USER}:${PI_USER}" "${R}/config/adguard/AdGuardHome.yaml" 2>/dev/null || true
cp /tmp/AdGuardHome.yaml "${R}/config/adguard/AdGuardHome.yaml"
cp /tmp/homepage-services.yaml "${R}/config/homepage/services.yaml"
[[ -f /tmp/Caddyfile ]] && cp /tmp/Caddyfile "${R}/config/caddy/Caddyfile"
REMOTE_DIR="${R}" bash "${R}/scripts/pi/fix-config-perms.sh"
if docker ps --format '{{.Names}}' | grep -q '^homepage$'; then
  docker restart homepage >/dev/null 2>&1 || true
fi
REMOTE

log "Tamamlandi"
