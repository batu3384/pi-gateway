#!/usr/bin/env bash
# AdGuard reklam engelleme drift onarimi (health-check / make adguard-tune)
set -euo pipefail
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REMOTE_DIR="${REMOTE_DIR:-/home/${USER}/pi-gateway}"
FIX=false
FIX_LIGHT=false
[[ "${1:-}" == "--fix" ]] && FIX=true
[[ "${1:-}" == "--fix-light" ]] && FIX_LIGHT=true

_pi_home_script() {
  local name="$1"
  local home="${REMOTE_DIR}/scripts/pi/${name}"
  if [[ -f "$home" ]]; then
    printf '%s\n' "$home"
  else
    printf '%s\n' "${SCRIPT_DIR}/${name}"
  fi
}

run_diagnose() {
  ADGUARD_SKIP_BYPASS_CHECK=true ADGUARD_BYPASS_CHECK=off \
    REMOTE_DIR="$REMOTE_DIR" bash "$(_pi_home_script diagnose-dns-bypass.sh)"
}

heal_light() {
  # ponytail: filter apply cache_clear tüm ev DNS'ini soğutur — yalnız dns+rewrite
  echo "[ensure-adguard] hedefli onarim (dns + rewrite)..."
  REMOTE_DIR="$REMOTE_DIR" bash "$(_pi_home_script apply-adguard-dns.sh)"
  REMOTE_DIR="$REMOTE_DIR" bash "$(_pi_home_script apply-adguard-rewrites.sh)"
}

heal_full() {
  echo "[ensure-adguard] tam configure-adguard..."
  REMOTE_DIR="$REMOTE_DIR" bash "$(_pi_home_script configure-adguard.sh)"
}

# health-check --fix-light: DNS zaten kirik; diagnose (nmap/audit) 30s+ ve .113 false FAIL.
if [[ "$FIX_LIGHT" == "true" ]]; then
  heal_light
  exit $?
fi

if run_diagnose; then
  exit 0
fi

if [[ "$FIX" != "true" ]]; then
  echo "[ensure-adguard] drift var — onarmak icin: $0 --fix-light veya --fix" >&2
  exit 1
fi

heal_light
if run_diagnose; then
  exit 0
fi

heal_full
echo "[ensure-adguard] yeniden teşhis..."
run_diagnose
