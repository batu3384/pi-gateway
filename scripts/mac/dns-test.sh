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
check "rewrite-git.home" bash -c "dig +time=3 +tries=1 @${PI_DNS} git.${LAN_DOMAIN} A +short | grep -qx '${PI_DNS}'"
check "rewrite-logs.home" bash -c "dig +time=3 +tries=1 @${PI_DNS} logs.${LAN_DOMAIN} A +short | grep -qx '${PI_DNS}'"
check "mac-gateway.home" bash -c "dig +time=3 +tries=1 gateway.${LAN_DOMAIN} +short | grep -qx '${PI_DNS}'"

echo "DNS test: $pass passed, $fail failed"
exit "$fail"
