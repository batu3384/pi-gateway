#!/usr/bin/env bash
# OpenBot native veri yolları (.env OPENBOT_STATE_DIR / OPENBOT_DATA_ROOT).
set -euo pipefail

openbot_data_root() {
  if [[ -n "${OPENBOT_DATA_ROOT:-}" ]]; then
    printf '%s\n' "$OPENBOT_DATA_ROOT"
    return 0
  fi
  local remote="${REMOTE_DIR:-${HOME}/pi-gateway}"
  if [[ -f "${remote}/.env" ]]; then
  # shellcheck disable=SC1090
    local v
    v="$(grep -E '^OPENBOT_DATA_ROOT=' "${remote}/.env" 2>/dev/null | head -1 | cut -d= -f2- | tr -d '"')"
    if [[ -n "$v" ]]; then
      printf '%s\n' "$v"
      return 0
    fi
  fi
  printf '%s\n' "/mnt/ssd/openbot-native"
}

openbot_state_dir() {
  if [[ -n "${OPENBOT_STATE_DIR:-}" ]]; then
    printf '%s\n' "$OPENBOT_STATE_DIR"
    return 0
  fi
  local remote="${REMOTE_DIR:-${HOME}/pi-gateway}"
  if [[ -f "${remote}/.env" ]]; then
    local v
    v="$(grep -E '^OPENBOT_STATE_DIR=' "${remote}/.env" 2>/dev/null | head -1 | cut -d= -f2- | tr -d '"')"
    if [[ -n "$v" ]]; then
      printf '%s\n' "$v"
      return 0
    fi
  fi
  local home="${HOME:-/home/${USER:-batu}}"
  if [[ -L "${home}/.config/OpenBot" ]]; then
    readlink -f "${home}/.config/OpenBot" 2>/dev/null && return 0
  fi
  printf '%s\n' "${home}/.config/OpenBot"
}

openbot_fx_file() {
  printf '%s\n' "$(openbot_data_root)/pi-gateway-fx-latest.txt"
}

openbot_db_path() {
  printf '%s\n' "$(openbot_state_dir)/openbot.db"
}

openbot_automation_dir() {
  printf '%s\n' "$(openbot_state_dir)/automation"
}