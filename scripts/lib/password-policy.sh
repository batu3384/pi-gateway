#!/usr/bin/env bash
# Ortak sifre politikasi (migrate, flash)
set -euo pipefail

enforce_password_policy() {
  local password="$1"
  local context="${2:-password}"
  local min_len="${PI_PASSWORD_MIN_LEN:-12}"

  [[ -n "$password" ]] || { echo "HATA: $context bos" >&2; return 1; }

  if [[ ${#password} -lt "$min_len" ]]; then
    if [[ "${WEAK_PASSWORD_OK:-}" == "yes" ]]; then
      echo "WARN: $context zayif (<${min_len}) — WEAK_PASSWORD_OK=yes" >&2
      return 0
    fi
    echo "HATA: $context en az ${min_len} karakter (veya WEAK_PASSWORD_OK=yes)" >&2
    return 1
  fi
  return 0
}
