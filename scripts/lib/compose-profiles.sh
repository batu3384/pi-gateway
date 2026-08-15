#!/usr/bin/env bash
# docker compose --profile bayraklari (.env'den)
set -euo pipefail

compose_profiles() {
  local -a profiles=()
  [[ "${ENABLE_AUTOHEAL:-false}" == "true" ]] && profiles+=(--profile autoheal)
  [[ "${ENABLE_CADDY:-true}" == "true" ]] && profiles+=(--profile caddy)
  [[ "${ENABLE_DOZZLE:-true}" == "true" ]] && profiles+=(--profile dozzle)
  [[ "${ENABLE_FORGEJO:-true}" == "true" ]] && profiles+=(--profile forgejo)
  [[ "${ENABLE_SYNCTHING:-true}" == "true" ]] && profiles+=(--profile syncthing)
  [[ "${ENABLE_REDIS:-false}" == "true" ]] && profiles+=(--profile redis)
  [[ "${ENABLE_N8N:-true}" == "true" ]] && profiles+=(--profile n8n)
  [[ "${ENABLE_NETALERTX:-true}" == "true" ]] && profiles+=(--profile netalert)
  [[ "${ENABLE_CROWDSEC:-true}" == "true" ]] && profiles+=(--profile crowdsec)
  [[ -n "${CLOUDFLARE_TUNNEL_TOKEN:-}" ]] && profiles+=(--profile cloudflare)
  [[ "${ENABLE_MONITORING:-true}" == "true" ]] && profiles+=(--profile monitoring)
  [[ "${ENABLE_WATCHTOWER:-false}" == "true" ]] && profiles+=(--profile watchtower)
  printf '%s\n' "${profiles[@]}"
}

load_compose_profiles() {
  profiles=()
  local profile
  while IFS= read -r profile; do
    [[ -n "$profile" ]] && profiles[${#profiles[@]}]="$profile"
  done < <(compose_profiles)
}
