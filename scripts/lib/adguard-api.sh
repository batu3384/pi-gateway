#!/usr/bin/env bash
# AdGuard Home API yardimcilari (pi scriptleri tarafindan source edilir)
set -euo pipefail

agh_login() {
  local base="$1" cookie="$2" user="$3" password="$4"
  local max_attempts="${5:-10}"
  local attempt

  for ((attempt = 1; attempt <= max_attempts; attempt++)); do
    if printf '%s\0%s' "$user" "$password" \
      | python3 -c 'import json,sys
raw=sys.stdin.buffer.read().split(b"\0",1)
if len(raw) != 2:
    raise SystemExit("credential payload missing")
print(json.dumps({"name": raw[0].decode("utf-8"), "password": raw[1].decode("utf-8")}, ensure_ascii=False))' \
      | curl -fsS -c "$cookie" -X POST "${base}/control/login" \
      -H 'Content-Type: application/json' \
      --data-binary @- >/dev/null 2>&1; then
      return 0
    fi
    sleep 2
  done
  return 1
}

agh_dns_info() {
  local base="$1" cookie="$2"
  curl -fsS -b "$cookie" "${base}/control/dns_info"
}
