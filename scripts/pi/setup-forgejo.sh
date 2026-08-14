#!/usr/bin/env bash
# Forgejo ilk kurulum + admin kullanicisini otomatik tamamlar
set -euo pipefail
REMOTE_DIR="${REMOTE_DIR:-/home/${USER}/pi-gateway}"
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
_PG_ENV_LIB="${SCRIPT_DIR:-$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)}/../lib/env-file.sh"
PG_SCRIPT_NAME="$(basename "$0")"
# shellcheck source=../lib/env-file.sh
source "${_PG_ENV_LIB:?}"
read_remote_dotenv || { echo "[${PG_SCRIPT_NAME:-script}] HATA: .env dotenv parser hatasi" >&2; exit 1; }
FORGEJO_PORT="${FORGEJO_PORT:-3002}"
FORGEJO_DOMAIN="${FORGEJO_DOMAIN:-git.${LAN_DOMAIN:-home}}"
FORGEJO_ADMIN_USER="${FORGEJO_ADMIN_USER:-admin}"
FORGEJO_ADMIN_PASSWORD="${FORGEJO_ADMIN_PASSWORD:-}"
FORGEJO_ADMIN_EMAIL="${FORGEJO_ADMIN_EMAIL:-admin@${LAN_DOMAIN:-home}.local}"
log() { echo "[forgejo-setup] $*"; }
[[ -n "$FORGEJO_ADMIN_PASSWORD" ]] || { log "FORGEJO_ADMIN_PASSWORD bos — atlandi"; exit 0; }
wait_up() {
  local attempt
  for ((attempt = 1; attempt <= 30; attempt++)); do
    curl -fsS "http://127.0.0.1:${FORGEJO_PORT}/" >/dev/null 2>&1 && return 0
    sleep 2
  done
  return 1
}
api_ready() {
  curl -fsS "http://127.0.0.1:${FORGEJO_PORT}/api/v1/version" >/dev/null 2>&1
}
run_install() {
  log "Forgejo kurulum sihirbazi tamamlaniyor..."
  curl -fsS -X POST "http://127.0.0.1:${FORGEJO_PORT}/" \
    -H "Content-Type: application/x-www-form-urlencoded" \
    --data-urlencode "db_type=sqlite3" \
    --data-urlencode "db_host=localhost:3306" \
    --data-urlencode "db_user=root" \
    --data-urlencode "db_passwd=" \
    --data-urlencode "db_name=gitea" \
    --data-urlencode "ssl_mode=disable" \
    --data-urlencode "db_path=/data/gitea/gitea.db" \
    --data-urlencode "app_name=Forgejo" \
    --data-urlencode "repo_root_path=/data/git/repositories" \
    --data-urlencode "lfs_root_path=/data/git/lfs" \
    --data-urlencode "run_user=git" \
    --data-urlencode "domain=${FORGEJO_DOMAIN}" \
    --data-urlencode "ssh_port=22" \
    --data-urlencode "http_port=3000" \
    --data-urlencode "app_url=http://${FORGEJO_DOMAIN}/" \
    --data-urlencode "log_root_path=/data/gitea/log" \
    --data-urlencode "admin_name=${FORGEJO_ADMIN_USER}" \
    --data-urlencode "admin_passwd=${FORGEJO_ADMIN_PASSWORD}" \
    --data-urlencode "admin_confirm_passwd=${FORGEJO_ADMIN_PASSWORD}" \
    --data-urlencode "admin_email=${FORGEJO_ADMIN_EMAIL}" >/dev/null
}
wait_up || { log "Forgejo hazir degil"; exit 1; }
if api_ready; then
  log "Forgejo zaten kurulu (API aktif)"
  if docker ps --format '{{.Names}}' | grep -q '^forgejo$'; then
    docker exec -u git forgejo forgejo admin user change-password \
      --username "${FORGEJO_ADMIN_USER}" \
      --password "${FORGEJO_ADMIN_PASSWORD}" 2>/dev/null \
      && log "Admin sifresi guncellendi: ${FORGEJO_ADMIN_USER}" \
      || log "Sifre guncelleme atlandi (zaten guncel veya yetki yok)"
    if [[ "${FORGEJO_ADMIN_USER}" =~ ^[a-zA-Z0-9._-]+$ ]]; then
      docker exec forgejo sqlite3 /data/gitea/gitea.db \
        "UPDATE user SET must_change_password=0 WHERE lower_name='${FORGEJO_ADMIN_USER}';" \
        2>/dev/null || true
    else
      log "WARN: Forgejo kullanici adi gecersiz — must_change_password atlandi"
    fi
  fi
  exit 0
fi
if ! run_install; then
  log "UYARI: Kurulum API basarisiz — http://127.0.0.1:${FORGEJO_PORT}"
  exit 1
fi
sleep 8
if api_ready; then
  log "Tamamlandi — http://${FORGEJO_DOMAIN}"
  exit 0
fi
log "UYARI: Kurulum sonrasi API yanit vermiyor — http://127.0.0.1:${FORGEJO_PORT}"
