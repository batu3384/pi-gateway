#!/usr/bin/env bash
# Tek sifre: Caddy + servis GUI'leri AGH_ADMIN_* ile hizalanir (UNIFIED_LOGIN=true).
# shellcheck shell=bash
# UNIFIED_LOGIN=true iken mevcut DOZZLE_* vs. .env degerleri EZILIR —
# aksi halde "tek sifre" yalan olur (eski per-service user kalir).

apply_unified_login() {
  [[ "${UNIFIED_LOGIN:-true}" == "true" ]] || return 0
  local user pass
  user="${AGH_ADMIN_USER:-admin}"
  pass="${AGH_ADMIN_PASSWORD:-}"
  [[ -n "$pass" ]] || return 0

  export CADDY_AUTH_USER="$user"
  export CADDY_AUTH_PASSWORD="$pass"
  export DOZZLE_ADMIN_USER="$user"
  export DOZZLE_ADMIN_PASSWORD="$pass"
  export UPTIME_KUMA_ADMIN_USER="$user"
  export UPTIME_KUMA_ADMIN_PASSWORD="$pass"
  export NETALERTX_PASSWORD="$pass"
  export GRAFANA_ADMIN_USER="$user"
  export GRAFANA_ADMIN_PASSWORD="$pass"
}
