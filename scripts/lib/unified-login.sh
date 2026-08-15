#!/usr/bin/env bash
# Tek sifre: Caddy + servis GUI'leri AGH_ADMIN_* ile hizalanir (UNIFIED_LOGIN=true).
# shellcheck shell=bash

apply_unified_login() {
  [[ "${UNIFIED_LOGIN:-true}" == "true" ]] || return 0
  local user pass
  user="${AGH_ADMIN_USER:-admin}"
  pass="${AGH_ADMIN_PASSWORD:-}"
  [[ -n "$pass" ]] || return 0

  export CADDY_AUTH_USER="${CADDY_AUTH_USER:-$user}"
  export CADDY_AUTH_PASSWORD="${CADDY_AUTH_PASSWORD:-$pass}"
  export DOZZLE_ADMIN_USER="${DOZZLE_ADMIN_USER:-$user}"
  export DOZZLE_ADMIN_PASSWORD="$pass"
  export UPTIME_KUMA_ADMIN_USER="${UPTIME_KUMA_ADMIN_USER:-$user}"
  export UPTIME_KUMA_ADMIN_PASSWORD="$pass"
  export FORGEJO_ADMIN_USER="${FORGEJO_ADMIN_USER:-$user}"
  export FORGEJO_ADMIN_PASSWORD="$pass"
  export SYNCTHING_GUI_USER="${SYNCTHING_GUI_USER:-$user}"
  export SYNCTHING_GUI_PASSWORD="$pass"
  export NETALERTX_PASSWORD="${NETALERTX_PASSWORD:-$pass}"
}
