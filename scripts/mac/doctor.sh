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
    if [[ "${UNIFIED_LOGIN:-true}" == "true" && "$name" != "RESTIC_PASSWORD" ]]; then
      ok "$name (unified login -> AGH_ADMIN_PASSWORD)"
      return 0
    fi
    if is_placeholder "$val"; then
      fail "$name empty or placeholder (required when enabled)"
    else
      ok "$name set"
    fi
  }

  check_pw "DOZZLE_ADMIN_PASSWORD" "${DOZZLE_ADMIN_PASSWORD:-}" "${ENABLE_DOZZLE:-true}"
  check_pw "RESTIC_PASSWORD" "${RESTIC_PASSWORD:-}" "${ENABLE_RESTIC:-true}"
  check_pw "UPTIME_KUMA_ADMIN_PASSWORD" "${UPTIME_KUMA_ADMIN_PASSWORD:-}" "true"
  check_pw "GRAFANA_ADMIN_PASSWORD" "${GRAFANA_ADMIN_PASSWORD:-}" "${ENABLE_MONITORING:-true}"

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

  case "${ROUTER_DNS_SECONDARY:-}" in
    1.1.1.1|1.0.0.1|8.8.8.8|8.8.4.4|9.9.9.9)
      warn "ROUTER_DNS_SECONDARY=${ROUTER_DNS_SECONDARY} public — WAN :53 drop timeout. Bos veya LAN_GATEWAY. make mac-dns ezer."
      ;;
  esac
  if [[ "${MAC_DNS_GATEWAY_FALLBACK:-false}" == "true" ]]; then
    warn "MAC_DNS_GATEWAY_FALLBACK=true — Mac DNS2 modem, LAN :53 reklam kacirir. Kilit: false."
  fi

  if [[ "$(uname)" == Darwin ]]; then
    _eth_ip="$(networksetup -getinfo Ethernet 2>/dev/null | awk -F': ' '/^IP address:/{print $2; exit}')"
    _eth_dns="$(networksetup -getdnsservers Ethernet 2>/dev/null || true)"
    _lan_pfx="${PI_STATIC_IP%.*}."
    # gateway IP string Pi IP icinde (ornek .1 ⊂ .11x) — *LAN_GATEWAY* false WARN.
    if [[ -n "${PI_STATIC_IP:-}" && -n "$_eth_ip" && "$_eth_ip" != "none" && "$_eth_ip" == "$_lan_pfx"* ]]; then
      if [[ "$_eth_dns" == *"aren't any DNS"* ]] \
        || { [[ -n "${LAN_GATEWAY:-}" ]] && printf '%s\n' "$_eth_dns" | grep -Fxq "$LAN_GATEWAY"; }; then
        warn "Ethernet LAN ($_eth_ip) DHCP/modem DNS — make mac-dns"
      elif printf '%s\n' "$_eth_dns" | grep -Fxq "$PI_STATIC_IP"; then
        ok "Ethernet DNS Pi"
      fi
    fi
    if command -v tailscale >/dev/null && tailscale status >/dev/null 2>&1; then
      if tailscale dns status 2>/dev/null | grep -q 'Tailscale DNS: enabled'; then
        ok "Tailscale DNS enabled (hedef: Pi 100.x AdGuard; Ethernet fe80/.1 ayri)"
      else
        warn "Tailscale DNS kapali — ev disi AdGuard yok. Admin Override + Use Tailscale DNS."
      fi
    fi
    unset _eth_ip _eth_dns _lan_pfx
  fi

  if [[ -z "${PI_USER:-}" ]]; then
    warn "PI_USER empty — default is pi"
  else
    ok "PI_USER=${PI_USER}"
  fi

  if [[ "${ENABLE_TLS:-true}" != "true" ]]; then
    if [[ "${WEAK_TLS_OK:-}" == "yes" ]]; then
      warn "ENABLE_TLS=false (WEAK_TLS_OK=yes) — HTTP on LAN"
    else
      fail "ENABLE_TLS=true required — make tls-certs (or WEAK_TLS_OK=yes)"
    fi
  else
    domain="${LAN_DOMAIN:-home}"
    if [[ -f "$PROJECT_DIR/config/caddy/certs/${domain}.pem" ]]; then
      ok "TLS certs present (config/caddy/certs/${domain}.pem)"
    else
      fail "ENABLE_TLS=true but certs missing — run: make tls-certs"
    fi
    if [[ "${ENABLE_N8N:-true}" == "true" && "${N8N_SECURE_COOKIE:-true}" != "true" ]]; then
      fail "N8N_SECURE_COOKIE=true required when ENABLE_TLS=true"
    fi
  fi

  # Offsite backup SLA (SSD restic alone is not 3-2-1)
  if [[ "${ENABLE_RESTIC:-true}" == "true" ]]; then
    max_age="${OFFSITE_BACKUP_MAX_AGE_DAYS:-7}"
    dest="${MAC_BACKUP_DEST:-$HOME/Backups/pi-gateway}"
    stamp="${dest}/.last-success"
    if [[ "$max_age" == "0" ]]; then
      ok "offsite backup age check disabled (OFFSITE_BACKUP_MAX_AGE_DAYS=0)"
    elif [[ ! -f "$stamp" ]]; then
      warn "no offsite backup stamp — run make backup-pull after first restic (3-2-1)"
    else
      age_days="$(python3 -c "import os,time; print(int((time.time()-os.path.getmtime('$stamp'))//86400))")"
      if (( age_days > max_age )); then
        if [[ "${WEAK_BACKUP_OK:-}" == "yes" ]]; then
          warn "offsite backup stale (${age_days}d > ${max_age}d) — WEAK_BACKUP_OK=yes"
        else
          fail "offsite backup stale (${age_days}d > ${max_age}d) — make backup-pull"
        fi
      else
        ok "offsite backup fresh (${age_days}d <= ${max_age}d)"
      fi
    fi
  fi

  # Deploy needs non-interactive SSH (key auth)
  ssh_target="${PI_HOST:-${PI_STATIC_IP:-}}"
  ssh_user="${PI_USER:-pi}"
  if [[ -n "$ssh_target" ]]; then
    if ssh -o ConnectTimeout=5 -o BatchMode=yes -o StrictHostKeyChecking=accept-new \
      "${ssh_user}@${ssh_target}" 'true' 2>/dev/null; then
      ok "SSH key auth: ${ssh_user}@${ssh_target}"
    else
      fail "SSH key auth failed for ${ssh_user}@${ssh_target} — run: ssh-copy-id ${ssh_user}@${ssh_target}"
    fi
  fi
fi

echo "[doctor] summary: fails=${fails} warns=${warns}"
if [[ "$fails" -gt 0 ]]; then
  echo "[doctor] Fix FAIL items before make install"
  exit 1
fi
echo "[doctor] Ready for make install / make deploy"
exit 0
