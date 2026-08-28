#!/usr/bin/env bash
# LAN'a RDNSS (Pi ULA) duyur — modem default router kalir (AdvDefaultLifetime 0).
# RFC 8106: modem RDNSS lifetime 0 = "artik kullanma". ZTE LAN IPv6 DNS UI yok.
set -euo pipefail
PATH="/usr/sbin:/sbin:${PATH}"
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
# ZTE LAN DNS genelde fe80::1. Baska LL ise MODEM_IPV6_DNS_LL.
MODEM_LL="${MODEM_IPV6_DNS_LL:-fe80::1}"
MODEM_LL="${MODEM_LL%%/*}"
log() { echo "[rdnss] $*"; }

if ! command -v radvd >/dev/null 2>&1; then
  log "radvd kuruluyor..."
  sudo DEBIAN_FRONTEND=noninteractive apt-get install -y -qq radvd ndisc6
elif ! command -v rdisc6 >/dev/null 2>&1; then
  log "ndisc6/rdisc6 kuruluyor..."
  sudo DEBIAN_FRONTEND=noninteractive apt-get install -y -qq ndisc6
fi

sudo tee /etc/radvd.conf >/dev/null <<EOF
# pi-gateway — DNS-only RA (default route modem'de kalir)
interface ${PI_IFACE} {
  AdvSendAdvert on;
  AdvManagedFlag off;
  AdvOtherConfigFlag off;
  AdvDefaultLifetime 0;
  AdvLinkMTU 1500;
  MinRtrAdvInterval 3;
  MaxRtrAdvInterval 4;
  RDNSS ${ULA} {
    AdvRDNSSLifetime 1800;
  };
  RDNSS ${MODEM_LL} {
    AdvRDNSSLifetime 0;
  };
};
EOF

sudo systemctl enable radvd
sudo systemctl restart radvd
sleep 1
if systemctl is-active --quiet radvd; then
  log "OK: radvd RDNSS=${ULA} lifetime=1800; ${MODEM_LL} lifetime=0 (iface ${PI_IFACE})"
else
  log "HATA: radvd baslamadi"
  systemctl status radvd --no-pager -l | head -20 || true
  exit 1
fi
log "Cihaz RFC 8106 anlarsa modem IPv6 DNS duser. Modem RA 900s tekrar basar — radvd 3–4s last-RA. Daemon ${MODEM_LL}:53 hâlâ cevaplar."
if [[ -f "$SCRIPT_DIR/observe-rdnss-ra.sh" ]]; then
  REMOTE_DIR="$REMOTE_DIR" bash "$SCRIPT_DIR/observe-rdnss-ra.sh" || \
    log "WARN: gerçek RA/RDNSS gözlemi başarısız — best-effort varsayımı korunuyor"
fi
