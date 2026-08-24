#!/usr/bin/env bash
# stdin → bülten arşivi + stdout. Yazılamazsa yine stdout geçer.
set -uo pipefail
slug="${1:-note}"
slug="$(printf '%s' "$slug" | tr -c 'a-zA-Z0-9._-' '_')"
body="$(cat)"
printf '%s\n' "$body"
[[ -n "${body// }" ]] || exit 0
dir="${BULLETIN_ARCHIVE_DIR:-/var/lib/pi-gateway/bulletins}"
if ! mkdir -p "$dir" 2>/dev/null || [[ ! -w "$dir" ]]; then
  dir="${HOME}/.hermes/bulletins"
  if ! mkdir -p "$dir" 2>/dev/null || [[ ! -w "$dir" ]]; then
    dir="/tmp/pi-gateway-bulletins"
    mkdir -p "$dir" 2>/dev/null || exit 0
  fi
fi
file="${dir}/$(date +%Y-%m-%d-%H%M)-${slug}.md"
printf '%s\n' "$body" >"$file" 2>/dev/null || true
exit 0
