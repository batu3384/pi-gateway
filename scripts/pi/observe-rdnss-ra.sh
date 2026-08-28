#!/usr/bin/env bash
# Gerçek LAN RA/RDNSS gözlemi — sonuç yoksa enforcement iddia etmez.
set -euo pipefail
PATH="/usr/sbin:/sbin:${PATH}"
REMOTE_DIR="${REMOTE_DIR:-/home/${USER}/pi-gateway}"
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=../lib/env-file.sh
source "$SCRIPT_DIR/../lib/env-file.sh"
read_remote_dotenv || {
  echo "[rdnss-observe] HATA: .env dotenv parser hatasi" >&2
  exit 1
}

PI_IFACE="${PI_INTERFACE:-eth0}"
ULA="${PI_IPV6_ULA:-}"
ULA="${ULA%%/*}"
MODEM_LL="${MODEM_IPV6_DNS_LL:-fe80::1}"
MODEM_LL="${MODEM_LL%%/*}"
log() { echo "[rdnss-observe] $*"; }

if ! command -v rdisc6 >/dev/null 2>&1; then
  log "WARN: rdisc6/ndisc6 yok — gerçek istemci RA gözlemi yapılamadı"
  exit 0
fi

runner=()
if [[ "${EUID:-$(id -u)}" -ne 0 ]]; then
  runner=(sudo)
fi
set +e
ra="$("${runner[@]}" timeout "${RDNSS_OBSERVE_TIMEOUT_SEC:-10}" rdisc6 -1 "$PI_IFACE" 2>&1)"
rc=$?
set -e
printf '%s\n' "$ra"
if [[ "$rc" -ne 0 && -z "$ra" ]]; then
  log "WARN: RA solicitasyonu cevap vermedi — enforcement best-effort"
  exit 0
fi

if grep -Fqi "$ULA" <<<"$ra"; then
  log "OK: Pi ULA RDNSS gözlendi (${ULA})"
else
  log "WARN: Pi ULA RDNSS bu gözlem penceresinde görülmedi"
fi
if grep -Fqi "$MODEM_LL" <<<"$ra"; then
  log "WARN: modem RDNSS (${MODEM_LL}) hâlâ gözlendi — IPv6 enforcement yok"
else
  log "WARN: modem RDNSS yokluğu kanıtlanmadı; rdisc6 tek RA döndürebilir"
fi
log "Sonuç: mevcut ZTE altında IPv6 DNS enforcement best-effort"
