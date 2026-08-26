#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=../lib/common.sh
source "$SCRIPT_DIR/../lib/common.sh"
load_env

PI_DNS="${PI_STATIC_IP:-${PI_HOST:-}}"
LAN_DOMAIN="${LAN_DOMAIN:-home}"

[[ -n "$PI_DNS" ]] || die "PI_STATIC_IP gerekli"

pass=0
fail=0

check() {
  local name="$1"
  shift
  if "$@" >/dev/null 2>&1; then
    echo "PASS $name"
    pass=$((pass + 1))
  else
    echo "FAIL $name"
    fail=$((fail + 1))
  fi
}

check "resolve-cloudflare" bash -c "test -n \"\$(dig +time=3 +tries=1 @${PI_DNS} cloudflare.com A +short | head -1)\""
check "block-doubleclick" bash -c "dig +time=3 +tries=1 @${PI_DNS} doubleclick.net A | grep -Eq '0\\.0\\.0\\.0|127\\.0\\.0\\.0|NXDOMAIN'"
check "block-doubleclick-aaaa" bash -c "aaaa=\$(dig +time=3 +tries=1 +short @${PI_DNS} doubleclick.net AAAA | head -1); [[ -z \"\$aaaa\" || \"\$aaaa\" == \"::\" || \"\$aaaa\" == \"::1\" ]]"
check "rewrite-gateway.home" bash -c "dig +time=3 +tries=1 @${PI_DNS} gateway.${LAN_DOMAIN} A +short | grep -qx '${PI_DNS}'"
check "rewrite-logs.home" bash -c "dig +time=3 +tries=1 @${PI_DNS} logs.${LAN_DOMAIN} A +short | grep -qx '${PI_DNS}'"
check "mac-gateway.home" bash -c "dig +time=3 +tries=1 gateway.${LAN_DOMAIN} +short | grep -qx '${PI_DNS}'"

if [[ "$(uname)" == "Darwin" ]]; then
  _r1="$(scutil --dns 2>/dev/null | awk '/^resolver #1/,/^resolver #2/')"
  # Tailscale resolver #1 = 100.100.100.100 — fe80/.1 orada gizlenir. Scoped = kablo/Wi-Fi.
  _scoped="$(scutil --dns 2>/dev/null | awk '/for scoped queries/{p=1;next} p')"
  # Tailscale #1 = 100.100.100.100 — Ethernet 8.8.8.8 orada gorunmez. Scoped = kablo/Wi-Fi.
  if grep -Eq 'nameserver\[[0-9]+\] : (1\.1\.1\.1|1\.0\.0\.1|8\.8\.8\.8|8\.8\.4\.4|9\.9\.9\.9)' <<<"${_r1}"$'\n'"${_scoped}"; then
    echo "FAIL mac-public-dns"
    fail=$((fail + 1))
  else
    echo "PASS mac-public-dns"
    pass=$((pass + 1))
  fi
  if grep -Eq 'nameserver\[[0-9]+\] : fe80::1' <<<"$_scoped"; then
    echo "FAIL mac-rdnss-modem (scoped fe80::1 — make mac-dns)"
    fail=$((fail + 1))
  else
    echo "PASS mac-rdnss-modem"
    pass=$((pass + 1))
  fi
  gw_re="${LAN_GATEWAY//./\\.}"
  if [[ -n "${LAN_GATEWAY:-}" ]] && grep -Eq "nameserver\\[[0-9]+\\] : ${gw_re}([[:space:]]|$)" <<<"$_scoped"; then
    echo "FAIL mac-dhcp-dns2-modem (scoped ${LAN_GATEWAY} — make mac-dns)"
    fail=$((fail + 1))
  else
    echo "PASS mac-dhcp-dns2-modem"
    pass=$((pass + 1))
  fi
  unset _r1 _scoped
fi

echo "DNS test: $pass passed, $fail failed"
exit "$fail"
