#!/usr/bin/env bash
# Parse simple dotenv assignments without evaluating shell syntax.

load_env_file() {
  local file="$1" line key value LC_ALL=C
  [[ -r "$file" ]] || return 0

  while IFS= read -r line || [[ -n "$line" ]]; do
    line="${line%$'\r'}"
    [[ -z "${line//[[:space:]]/}" || "$line" =~ ^[[:space:]]*# ]] && continue
    [[ "$line" =~ ^[[:space:]]*([A-Za-z_][A-Za-z0-9_]*)=(.*)$ ]] \
      || return 1

    key="${BASH_REMATCH[1]}"
    value="${BASH_REMATCH[2]}"
    value="${value#"${value%%[![:space:]]*}"}"
    value="${value%"${value##*[![:space:]]}"}"
    if [[ "$value" == \'*\' && "$value" == *\' ]]; then
      value="${value:1:${#value}-2}"
    elif [[ "$value" == \"*\" && "$value" == *\" ]]; then
      value="${value:1:${#value}-2}"
      value="${value//\\\"/\"}"
      value="${value//\\\\/\\}"
    elif [[ "$value" =~ ^(.*[^[:space:]])[[:space:]]+#.*$ ]]; then
      value="${BASH_REMATCH[1]}"
      value="${value%"${value##*[![:space:]]}"}"
    fi
    if [[ "$(id -u)" -eq 0 ]]; then
      case "$key" in
        PATH|LD_*|BASH_ENV|ENV|PYTHON*|SCRIPT_DIR|PI_GATEWAY_LIB_DIR|IFS|CDPATH|SHELLOPTS|BASHOPTS|HOME|USER)
          continue
          ;;
        REMOTE_DIR)
          [[ -n "${REMOTE_DIR:-}" ]] && continue
          ;;
      esac
    fi
    printf -v "$key" '%s' "$value"
    # shellcheck disable=SC2163 # key is validated as a shell identifier above.
    export "$key"
  done <"$file"
}

read_dotenv_strict() {
  local file="$1"
  [[ -r "$file" ]] || return 0
  load_env_file "$file"
}

read_remote_dotenv() {
  local remote="${REMOTE_DIR:-}"
  [[ -n "$remote" && -f "$remote/.env" ]] || return 0
  read_dotenv_strict "$remote/.env" || return 1
  # UNIFIED_LOGIN: force AGH_* onto service GUI vars after dotenv load
  # shellcheck source=unified-login.sh
  source "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/unified-login.sh"
  apply_unified_login
}

read_project_dotenv() {
  local project="${PROJECT_DIR:-}"
  [[ -n "$project" && -f "$project/.env" ]] || return 0
  read_dotenv_strict "$project/.env" || return 1
  # shellcheck source=unified-login.sh
  source "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/unified-login.sh"
  apply_unified_login
}

read_project_or_example_dotenv() {
  local project="${PROJECT_DIR:-}"
  if [[ -n "$project" && -f "$project/.env" ]]; then
    read_dotenv_strict "$project/.env"
  elif [[ -n "$project" && -f "$project/.env.example" ]]; then
    read_dotenv_strict "$project/.env.example"
  fi
}
