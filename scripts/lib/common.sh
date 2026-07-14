#!/usr/bin/env bash
set -euo pipefail

PROJECT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"

load_env() {
  if [[ -f "$PROJECT_DIR/.env" ]]; then
    # shellcheck source=/dev/null
    source "$PROJECT_DIR/.env"
  elif [[ -f "$PROJECT_DIR/.env.example" ]]; then
    # shellcheck source=/dev/null
    source "$PROJECT_DIR/.env.example"
  fi
}

log() { printf '[pi-gateway] %s\n' "$*"; }
die() { log "ERROR: $*"; exit 1; }

require_cmd() {
  local cmd
  for cmd in "$@"; do
    command -v "$cmd" >/dev/null 2>&1 || die "Missing command: $cmd"
  done
}

cidr_prefix() {
  python3 - "$1" <<'PY'
import ipaddress, sys
print(ipaddress.ip_network(sys.argv[1], strict=False).prefixlen)
PY
}

subnet_mask_from_prefix() {
  python3 - "$1" <<'PY'
import ipaddress, sys
print(ipaddress.ip_network(f"0.0.0.0/{sys.argv[1]}", strict=False).netmask)
PY
}

ip_to_int() {
  python3 - "$1" <<'PY'
import ipaddress, sys
print(int(ipaddress.ip_address(sys.argv[1])))
PY
}

generate_dhcp_range() {
  python3 - "$1" "$2" <<'PY'
import ipaddress, sys
net = ipaddress.ip_network(sys.argv[1], strict=False)
gateway = ipaddress.ip_address(sys.argv[2])
hosts = [h for h in net.hosts() if h != gateway]
if len(hosts) < 20:
    raise SystemExit('Subnet too small for DHCP range')
start = hosts[9] if len(hosts) > 9 else hosts[1]
end = hosts[-10] if len(hosts) > 20 else hosts[-2]
print(f"{start}\n{end}")
PY
}

generate_password_hash() {
  local user="$1" pass="$2"
  if command -v htpasswd >/dev/null 2>&1; then
    htpasswd -nbB "$user" "$pass" | cut -d: -f2-
  elif docker info >/dev/null 2>&1; then
    docker run --rm httpd:2-alpine htpasswd -nbB "$user" "$pass" | cut -d: -f2-
  else
    die "Need htpasswd or Docker to generate AdGuard password hash"
  fi
}
