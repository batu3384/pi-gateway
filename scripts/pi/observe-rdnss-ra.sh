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
  exit 2
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
  exit 2
fi

if grep -Fqi "$ULA" <<<"$ra"; then
  log "OK: Pi ULA RDNSS gözlendi (${ULA})"
else
  log "WARN: Pi ULA RDNSS bu gözlem penceresinde görülmedi"
fi

if [[ "$rc" -ne 0 ]]; then
  log "WARN: rdisc6 non-zero dondu — RA sonucu kesin degil"
  exit 2
fi

modem_state="$(
  RA_TEXT="$ra" python3 - "$MODEM_LL" <<'PY'
import os
import re
import sys

needle = sys.argv[1].lower()
lines = os.environ.get("RA_TEXT", "").splitlines()
states = set()
for index, line in enumerate(lines):
    if needle not in line.lower():
        continue
    window_lines = []
    for offset, candidate in enumerate(lines[index : index + 4]):
        if offset and "recursive dns server" in candidate.lower():
            break
        window_lines.append(candidate)
    window = "\n".join(window_lines)
    values = [
        int(value)
        for value in re.findall(
            r"(?:dns\s+)?(?:valid\s+)?lifetime[^0-9]*(\d+)",
            window,
            flags=re.IGNORECASE,
        )
    ]
    if not values:
        states.add("unknown")
    elif any(value > 0 for value in values):
        states.add("positive")
    else:
        states.add("zero")

if "positive" in states:
    print("positive")
elif "unknown" in states:
    print("unknown")
elif "zero" in states:
    print("zero")
else:
    print("absent")
PY
)"
case "$modem_state" in
  zero)
    log "OK: modem RDNSS (${MODEM_LL}) lifetime=0 — withdrawn"
    ;;
  positive)
    log "WARN: modem RDNSS (${MODEM_LL}) positive lifetime — IPv6 bypass yolu acik"
    ;;
  unknown)
    log "WARN: modem RDNSS lifetime okunamadi — enforcement kaniti yok"
    ;;
  absent)
    log "WARN: modem RDNSS yoklugu kanitlanmadi; rdisc6 tek RA dondurebilir"
    ;;
esac
log "Sonuç: mevcut ZTE altında IPv6 DNS enforcement best-effort"
if grep -Fqi "$ULA" <<<"$ra" && [[ "$modem_state" == "zero" ]]; then
  exit 0
fi
exit 2
