#!/usr/bin/env bash
# LAN'a RDNSS (Pi ULA) duyur — modem default router kalir (AdvDefaultLifetime 0).
# ZTE H3600P LAN IPv6 DNS UI yok; modem RDNSS=fe80::1. Bu ek RDNSS ekler, IPv6 kapatmaz.
set -euo pipefail
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REMOTE_DIR="${REMOTE_DIR:-/home/${USER}/pi-gateway}"
_PG_ENV_LIB="${SCRIPT_DIR}/../lib/env-file.sh"
PG_SCRIPT_NAME="$(basename "$0")"
# shellcheck source=../lib/env-file.sh
source "${_PG_ENV_LIB:?}"
read_remote_dotenv || { echo "[${PG_SCRIPT_NAME}] HATA: .env" >&2; exit 1; }

PI_IFACE="${PI_INTERFACE:-eth0}"
ULA="${PI_IPV6_ULA:-}"
ULA="${ULA%%/*}"
[[ -n "$ULA" ]] || { echo "[rdnss] HATA: PI_IPV6_ULA bos" >&2; exit 1; }
log() { echo "[rdnss] $*"; }

if ! command -v radvd >/dev/null 2>&1; then
  log "radvd kuruluyor..."
  sudo DEBIAN_FRONTEND=noninteractive apt-get install -y -qq radvd
fi

sudo tee /etc/radvd.conf >/dev/null <<EOF
# pi-gateway — DNS-only RA (default route modem'de kalir)
interface ${PI_IFACE} {
  AdvSendAdvert on;
  AdvManagedFlag off;
  AdvOtherConfigFlag off;
  AdvDefaultLifetime 0;
  AdvLinkMTU 1500;
  MinRtrAdvInterval 10;
  MaxRtrAdvInterval 30;
  RDNSS ${ULA} {
    AdvRDNSSLifetime 600;
  };
};
EOF

sudo systemctl enable radvd
sudo systemctl restart radvd
sleep 1
if systemctl is-active --quiet radvd; then
  log "OK: radvd RDNSS=${ULA} (iface ${PI_IFACE})"
else
  log "HATA: radvd baslamadi"
  systemctl status radvd --no-pager -l | head -20 || true
  exit 1
fi
log "Cihazlar yeni RA sonrasi IPv6 DNS olarak ${ULA} da gorecek (modem fe80::1 yaninda)"
