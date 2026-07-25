#!/usr/bin/env bash
# Mac/dev host: prerequisite checks before install/deploy
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=../lib/common.sh
source "$SCRIPT_DIR/../lib/common.sh"

fails=0
warns=0

ok() { printf '[doctor] OK: %s\n' "$*"; }
warn() { printf '[doctor] WARN: %s\n' "$*"; warns=$((warns + 1)); }
fail() { printf '[doctor] FAIL: %s\n' "$*"; fails=$((fails + 1)); }

is_placeholder() {
  local v="${1:-}"
  case "$v" in
    ""|CHANGE_ME*|Degistir*|changeme*|password|admin) return 0 ;;
    *) return 1 ;;
  esac
}

require_cmd_soft() {
  local cmd="$1"
  if command -v "$cmd" >/dev/null 2>&1; then
    ok "command: $cmd"
  else
    fail "missing command: $cmd"
  fi
}

require_cmd_soft docker
require_cmd_soft ssh
require_cmd_soft python3

if command -v shellcheck >/dev/null 2>&1; then
  ok "command: shellcheck"
else
  warn "shellcheck not installed (optional for local lint)"
fi

if [[ ! -f "$PROJECT_DIR/.env" ]]; then
  fail ".env missing — run: cp .env.example .env"
else
  ok ".env present"
  load_env
fi

if [[ -f "$PROJECT_DIR/.env" ]]; then
  if is_placeholder "${AGH_ADMIN_PASSWORD:-}"; then
    fail "AGH_ADMIN_PASSWORD empty or placeholder"
  elif [[ "${#AGH_ADMIN_PASSWORD}" -lt 12 ]]; then
    fail "AGH_ADMIN_PASSWORD must be at least 12 characters"
  else
    ok "AGH_ADMIN_PASSWORD set"
  fi

  check_pw() {
    local name="$1" val="$2" enabled="$3"
    [[ "$enabled" == "true" ]] || return 0
    if is_placeholder "$val"; then
      fail "$name empty or placeholder (required when enabled)"
    else
      ok "$name set"
    fi
  }

  check_pw "DOZZLE_ADMIN_PASSWORD" "${DOZZLE_ADMIN_PASSWORD:-}" "${ENABLE_DOZZLE:-true}"
  check_pw "FORGEJO_ADMIN_PASSWORD" "${FORGEJO_ADMIN_PASSWORD:-}" "${ENABLE_FORGEJO:-true}"
  check_pw "SYNCTHING_GUI_PASSWORD" "${SYNCTHING_GUI_PASSWORD:-}" "${ENABLE_SYNCTHING:-true}"
  check_pw "RESTIC_PASSWORD" "${RESTIC_PASSWORD:-}" "${ENABLE_RESTIC:-true}"
  check_pw "UPTIME_KUMA_ADMIN_PASSWORD" "${UPTIME_KUMA_ADMIN_PASSWORD:-}" "true"

  if [[ "${ENABLE_N8N:-true}" == "true" ]]; then
    if [[ -z "${N8N_ENCRYPTION_KEY:-}" ]]; then
      fail "N8N_ENCRYPTION_KEY required when ENABLE_N8N=true (openssl rand -hex 24)"
    elif [[ "${#N8N_ENCRYPTION_KEY}" -lt 32 ]]; then
      fail "N8N_ENCRYPTION_KEY must be at least 32 characters"
    else
      ok "N8N_ENCRYPTION_KEY set"
    fi
  fi

  if [[ -z "${PI_STATIC_IP:-}" ]]; then
    warn "PI_STATIC_IP empty — run make discover when Pi is online"
  else
    ok "PI_STATIC_IP=${PI_STATIC_IP}"
  fi

  if [[ -z "${PI_USER:-}" ]]; then
    warn "PI_USER empty — default is pi"
  else
    ok "PI_USER=${PI_USER}"
  fi
fi

echo "[doctor] summary: fails=${fails} warns=${warns}"
if [[ "$fails" -gt 0 ]]; then
  echo "[doctor] Fix FAIL items before make install"
  exit 1
fi
echo "[doctor] Ready for make install / make deploy"
exit 0
