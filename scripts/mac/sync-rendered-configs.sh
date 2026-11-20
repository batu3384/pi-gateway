#!/usr/bin/env bash
# Render edilmis config + .env dosyalarini Pi'ye gonderir
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=../lib/common.sh
source "$SCRIPT_DIR/../lib/common.sh"
load_env

PI_USER="${PI_USER:-pi}"
PI_HOST="${PI_DEPLOY_HOST:-$(deploy_host)}"
REMOTE_DIR="${REMOTE_DIR:-/home/$PI_USER/pi-gateway}"

[[ -n "$PI_HOST" ]] || die "PI_DEPLOY_HOST veya PI_STATIC_IP gerekli"

log "Rendered configs -> ${PI_USER}@${PI_HOST}"

CFG_STAGE="${REMOTE_DIR}/.deploy-tmp-cfg.$$"
ssh -o ConnectTimeout=15 "${PI_USER}@${PI_HOST}" "install -d -m 700 '${CFG_STAGE}'"
scp "$PROJECT_DIR/.env" "${PI_USER}@${PI_HOST}:${CFG_STAGE}/pi-gateway.env.new"
scp "$PROJECT_DIR/config/adguard/AdGuardHome.yaml" "${PI_USER}@${PI_HOST}:${CFG_STAGE}/AdGuardHome.yaml"
[[ -f "$PROJECT_DIR/config/caddy/Caddyfile" ]] && \
  scp "$PROJECT_DIR/config/caddy/Caddyfile" "${PI_USER}@${PI_HOST}:${CFG_STAGE}/Caddyfile" || true
[[ -f "$PROJECT_DIR/config/glance/glance.yml" ]] && \
  scp "$PROJECT_DIR/config/glance/glance.yml" "${PI_USER}@${PI_HOST}:${CFG_STAGE}/glance.yml" || true
[[ -f "$PROJECT_DIR/config/gatus/config.yaml" ]] && \
  scp "$PROJECT_DIR/config/gatus/config.yaml" "${PI_USER}@${PI_HOST}:${CFG_STAGE}/gatus-config.yaml" || true

ssh "${PI_USER}@${PI_HOST}" "REMOTE_DIR='${REMOTE_DIR}' PI_USER='${PI_USER}' CFG_STAGE='${CFG_STAGE}' bash -s" <<'REMOTE'
set -euo pipefail
R="${REMOTE_DIR:-/home/${PI_USER}/pi-gateway}"
STAGE="${CFG_STAGE}"
trap 'rm -rf "$STAGE"' EXIT
NEW="${STAGE}/pi-gateway.env.new"
OLD="${R}/.env"
PRESERVE='N8N_ENCRYPTION_KEY CROWDSEC_BOUNCER_KEY CROWDSEC_API_KEY'
python3 - "$NEW" "$OLD" "$OLD" $PRESERVE <<'PY'
import os
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
os.chmod(out_path, 0o600)
print("[env-merge] ok")
PY
chmod 600 "$OLD"
# Container (adguard root) dosyayi root'a cevirebilir — cp oncesi sahiplik
sudo chown "${PI_USER}:${PI_USER}" "${R}/config/adguard/AdGuardHome.yaml" 2>/dev/null || true
# Canli AGH yaml API state (rewrite). Render edilmis Mac kopyasi her deploy'da siler.
if [[ -s "${R}/config/adguard/AdGuardHome.yaml" ]]; then
  echo "[sync] AdGuardHome.yaml mevcut — uzerine yazilmadi"
else
  cp "${STAGE}/AdGuardHome.yaml" "${R}/config/adguard/AdGuardHome.yaml"
fi
caddy_changed=0
if [[ -f "${STAGE}/Caddyfile" ]]; then
  if [[ ! -f "${R}/config/caddy/Caddyfile" ]] || ! cmp -s "${STAGE}/Caddyfile" "${R}/config/caddy/Caddyfile"; then
    cp "${STAGE}/Caddyfile" "${R}/config/caddy/Caddyfile"
    echo "[sync] Caddyfile guncellendi"
    caddy_changed=1
  else
    echo "[sync] Caddyfile ayni"
  fi
fi
glance_changed=0
if [[ -f "${STAGE}/glance.yml" ]]; then
  mkdir -p "${R}/config/glance"
  if [[ ! -f "${R}/config/glance/glance.yml" ]] || ! cmp -s "${STAGE}/glance.yml" "${R}/config/glance/glance.yml"; then
    cp "${STAGE}/glance.yml" "${R}/config/glance/glance.yml"
    echo "[sync] glance.yml guncellendi"
    glance_changed=1
  else
    echo "[sync] glance.yml ayni"
  fi
fi
gatus_changed=0
if [[ -f "${STAGE}/gatus-config.yaml" ]]; then
  mkdir -p "${R}/config/gatus"
  if [[ ! -f "${R}/config/gatus/config.yaml" ]] || ! cmp -s "${STAGE}/gatus-config.yaml" "${R}/config/gatus/config.yaml"; then
    cp "${STAGE}/gatus-config.yaml" "${R}/config/gatus/config.yaml"
    echo "[sync] gatus/config.yaml guncellendi"
    gatus_changed=1
  else
    echo "[sync] gatus/config.yaml ayni"
  fi
fi
REMOTE_DIR="${R}" bash "${R}/scripts/pi/fix-config-perms.sh"
if [[ "$caddy_changed" == "1" ]]; then
  if [[ -x "${R}/scripts/pi/setup-caddy-lan-ip.sh" ]]; then
    REMOTE_DIR="${R}" bash "${R}/scripts/pi/setup-caddy-lan-ip.sh" \
      || echo "[sync] WARN: setup-caddy-lan-ip atlandi"
  fi
  if [[ -f "${R}/config/caddy/.tailscale-serve-block" && -x "${R}/scripts/pi/setup-tailscale-serve.sh" ]]; then
    REMOTE_DIR="${R}" bash "${R}/scripts/pi/setup-tailscale-serve.sh" \
      || echo "[sync] WARN: setup-tailscale-serve atlandi"
  fi
  if docker ps --format '{{.Names}}' | grep -qx 'caddy'; then
    docker exec caddy caddy reload --config /etc/caddy/Caddyfile >/dev/null 2>&1 \
      || echo "[sync] WARN: caddy reload basarisiz"
  fi
fi
if [[ "$glance_changed" == "1" ]] && docker ps --format '{{.Names}}' | grep -qx 'glance'; then
  docker restart glance >/dev/null 2>&1 || echo "[sync] WARN: glance restart basarisiz"
fi
if [[ "$gatus_changed" == "1" ]] && docker ps --format '{{.Names}}' | grep -qx 'gatus'; then
  docker restart gatus >/dev/null 2>&1 || echo "[sync] WARN: gatus restart basarisiz"
fi
REMOTE

log "Tamamlandi"
