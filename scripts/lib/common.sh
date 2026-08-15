#!/usr/bin/env bash
set -euo pipefail

# Sourced by mac/pi scripts for PROJECT_DIR + helpers
# shellcheck disable=SC2034
PROJECT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"

load_env() {
  # shellcheck source=env-file.sh
  source "$(dirname "${BASH_SOURCE[0]}")/env-file.sh"
  read_project_or_example_dotenv || die ".env dotenv parser hatasi"
  # shellcheck source=unified-login.sh
  source "$(dirname "${BASH_SOURCE[0]}")/unified-login.sh"
  apply_unified_login
}

log() { printf '[pi-gateway] %s\n' "$*"; }
die() { log "ERROR: $*"; exit 1; }

default_pi_user() { echo "${PI_USER:-pi}"; }

default_remote_dir() {
  echo "${REMOTE_DIR:-/home/$(default_pi_user)/pi-gateway}"
}

deploy_host() { echo "${PI_STATIC_IP:-${PI_HOST:-}}"; }

require_deploy_host() {
  local h
  h="$(deploy_host)"
  [[ -n "$h" ]] || die "PI_STATIC_IP veya PI_HOST gerekli (.env)"
  echo "$h"
}

require_pi_static_ip() {
  [[ -n "${PI_STATIC_IP:-}" ]] || die "PI_STATIC_IP gerekli (.env)"
  echo "$PI_STATIC_IP"
}

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
