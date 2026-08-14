#!/usr/bin/env bash
# n8n credential sifreleme anahtari — bos ise otomatik uretir (.env'e yazar)
set -euo pipefail
REMOTE_DIR="${REMOTE_DIR:-/home/${USER}/pi-gateway}"
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
_PG_ENV_LIB="${SCRIPT_DIR:-$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)}/../lib/env-file.sh"
PG_SCRIPT_NAME="$(basename "$0")"
# shellcheck source=../lib/env-file.sh
source "${_PG_ENV_LIB:?}"
read_remote_dotenv || { echo "[${PG_SCRIPT_NAME:-script}] HATA: .env dotenv parser hatasi" >&2; exit 1; }
log() { echo "[n8n-encryption-key] $*"; }
[[ "${ENABLE_N8N:-true}" == "true" ]] || { log "n8n kapali"; exit 0; }
if [[ -n "${N8N_ENCRYPTION_KEY:-}" && "${#N8N_ENCRYPTION_KEY}" -ge 32 ]]; then
  log "N8N_ENCRYPTION_KEY mevcut"
  exit 0
fi
key="$(openssl rand -hex 24)"
created=1
if grep -q '^N8N_ENCRYPTION_KEY=' "$REMOTE_DIR/.env" 2>/dev/null; then
  sed -i "s|^N8N_ENCRYPTION_KEY=.*|N8N_ENCRYPTION_KEY=${key}|" "$REMOTE_DIR/.env"
else
  printf '\nN8N_ENCRYPTION_KEY=%s\n' "$key" >>"$REMOTE_DIR/.env"
fi
export N8N_ENCRYPTION_KEY="$key"
log "N8N_ENCRYPTION_KEY olusturuldu (.env guncellendi)"
if [[ "${created:-0}" -eq 1 ]] && docker ps --format '{{.Names}}' | grep -q '^n8n$'; then
  log "n8n yeniden baslatiliyor (yeni encryption key)"
  docker restart n8n >/dev/null 2>&1 || true
  for _ in 1 2 3 4 5 6 7 8 9 10 11 12; do
    sleep 5
    curl -fsS "http://127.0.0.1:${N8N_PORT:-5678}/healthz" >/dev/null 2>&1 && break
  done
fi
