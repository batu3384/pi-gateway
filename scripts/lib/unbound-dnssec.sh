#!/usr/bin/env bash
# Unbound :5335 DNSSEC probes. AGH AD kopyalayabilir — kanıt Unbound'a bak.
# flags satirinda ADDITIONAL kelimesi 'ad' icerir; yalniz flags: ... ad; esle.

unbound_dnssec_ad_ok() {
  local port="${1:-${UNBOUND_PORT:-5335}}"
  dig +dnssec +time=2 +tries=1 @127.0.0.1 -p "$port" cloudflare.com A 2>/dev/null \
    | grep -qE '^;; flags: [^;]*[[:space:]]ad;'
}

# Comcast bogus-signature domain. +time=3 ilk cache miss'te timeout olabilir.
unbound_dnssec_sigfail_ok() {
  local port="${1:-${UNBOUND_PORT:-5335}}"
  local st
  st="$(dig +time=8 +tries=1 @127.0.0.1 -p "$port" dnssec-failed.org A 2>/dev/null \
    | awk '/status:/{gsub(/,/, "", $6); print $6; exit}')"
  [[ "$st" == "SERVFAIL" ]]
}
