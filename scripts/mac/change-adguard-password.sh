#!/usr/bin/env bash
# AdGuard admin sifresini .env uzerinden gunceller ve Pi'ye uygular
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=../lib/common.sh
source "$SCRIPT_DIR/../lib/common.sh"
load_env

PI_HOST="${PI_STATIC_IP:-${PI_HOST:-}}"
PI_USER="${PI_USER:-pi}"
REMOTE_DIR="${REMOTE_DIR:-/home/$PI_USER/pi-gateway}"
ENV_FILE="$PROJECT_DIR/.env"

usage() {
  cat <<EOF
Kullanim:
  $0 'YeniSifren123!'
  $0   # interaktif (sifre ekranda gorunmez)

Not: AdGuard panelinde sifre degistirme yoktur; bu script kullanilir.
EOF
}

NEW_PASS="${1:-}"
if [[ -z "$NEW_PASS" ]]; then
  read -r -s -p "Yeni AdGuard sifresi (min 12 karakter): " NEW_PASS
  echo
  read -r -s -p "Tekrar: " NEW_PASS2
  echo
  [[ "$NEW_PASS" == "$NEW_PASS2" ]] || die "Sifreler eslesmiyor"
fi

[[ "${#NEW_PASS}" -ge 12 ]] || die "Sifre en az 12 karakter olmali"

log "Sifre .env dosyasina yaziliyor..."
python3 - "$ENV_FILE" "$NEW_PASS" <<'PY'
import sys
from pathlib import Path

path = Path(sys.argv[1])
password = sys.argv[2]
lines = path.read_text().splitlines() if path.exists() else []
out, found = [], False
for line in lines:
    if line.startswith("AGH_ADMIN_PASSWORD="):
        out.append(f"AGH_ADMIN_PASSWORD={password}")
        found = True
    else:
        out.append(line)
if not found:
    out.append(f"AGH_ADMIN_PASSWORD={password}")
path.write_text("\n".join(out) + "\n")
PY

log "Config render ediliyor..."
bash "$SCRIPT_DIR/render-config.sh"

log "Pi'ye gonderiliyor ve AdGuard yeniden baslatiliyor..."
scp "$PROJECT_DIR/config/adguard/AdGuardHome.yaml" "${PI_USER}@${PI_HOST}:/tmp/AdGuardHome.yaml"
ssh "${PI_USER}@${PI_HOST}" "sudo cp /tmp/AdGuardHome.yaml ${REMOTE_DIR}/config/adguard/AdGuardHome.yaml && sudo chown ${PI_USER}:${PI_USER} ${REMOTE_DIR}/config/adguard/AdGuardHome.yaml && docker restart adguard"

log "Tamam."
log "Giris: http://${PI_HOST}:8080"
log "Kullanici: ${AGH_ADMIN_USER:-admin}"
log "Sifre: (az once girdigin)"
