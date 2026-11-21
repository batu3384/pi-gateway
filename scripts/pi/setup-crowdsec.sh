#!/usr/bin/env bash
# CrowdSec kalici config + temiz baslangic (crash loop onarimi)
set -euo pipefail

REMOTE_DIR="${REMOTE_DIR:-/home/${USER}/pi-gateway}"
DATA="${REMOTE_DIR}/data/crowdsec"
CONFIG="${DATA}/config"
DB="${DATA}/db"

log() { echo "[crowdsec-setup] $*"; }

mkdir -p "$CONFIG" "$DB"

# Eski duz yapiyi tasima (tek seferlik)
if [[ -f "${DATA}/crowdsec.db" ]]; then
  log "Eski db tasinyor -> db/"
  mv "${DATA}/crowdsec.db" "${DB}/" 2>/dev/null || true
fi
for f in GeoLite2-ASN.mmdb GeoLite2-City.mmdb crowdsec.db.bak-*; do
  [[ -e "${DATA}/$f" ]] && mv "${DATA}/$f" "${DB}/" 2>/dev/null || true
done
rm -f "${DATA}/trace" 2>/dev/null || true

# Bozuk state: yalnizca --reset ile sifirla (deploy her seferinde silmesin)
if [[ "${1:-}" == "--reset" ]]; then
  log "Temiz kurulum (--reset): config + db"
  rm -rf "${CONFIG:?}"/* "${DB:?}"/* 2>/dev/null || true
  mkdir -p "$CONFIG" "$DB"
elif [[ ! -f "${CONFIG}/config.yaml" ]]; then
  log "Ilk kurulum: bos config/db"
  mkdir -p "$CONFIG" "$DB"
fi

# AdGuard host:8080 ile cakismasin — LAPI 8082 (network_mode: host)
bootstrap_default_config() {
  local cfg="${CONFIG}/config.yaml"
  local lines=0
  if [[ -f "$cfg" ]]; then
    lines="$(wc -l <"$cfg" 2>/dev/null || echo 0)"
  fi
  if [[ ! -f "$cfg" || "${lines:-0}" -lt 20 ]]; then
    log "Varsayilan config.yaml imajdan cikariliyor (/staging/etc/crowdsec/config.yaml)"
    local tmp_cfg
    tmp_cfg="$(mktemp)"
    if (cd "${REMOTE_DIR}/compose" && docker compose --env-file ../.env --profile crowdsec \
        run --rm --no-deps --entrypoint cat crowdsec /staging/etc/crowdsec/config.yaml >"$tmp_cfg" 2>/dev/null) \
      && [[ -s "$tmp_cfg" ]]; then
      mv "$tmp_cfg" "$cfg"
    else
      rm -f "$tmp_cfg"
      log "HATA: CrowdSec varsayilan config.yaml imajdan alinamadi" >&2
      return 1
    fi
  fi
}
ensure_lapi_listen_port() {
  local cfg="${CONFIG}/config.yaml"
  bootstrap_default_config
  if grep -qE '^[[:space:]]*listen_uri:' "$cfg"; then
    sed -i -E 's|^([[:space:]]*)listen_uri:.*|\1listen_uri: 127.0.0.1:8082|' "$cfg"
  else
    printf '\napi:\n  server:\n    listen_uri: 127.0.0.1:8082\n' >>"$cfg"
  fi
}
ensure_lapi_credentials() {
  local cred="${CONFIG}/local_api_credentials.yaml"
  if [[ -f "$cred" ]] && grep -q '^url:' "$cred"; then
    sed -i 's|^url:.*|url: http://127.0.0.1:8082|' "$cred"
  fi
}
ensure_journal_feed() {
  sudo mkdir -p /run/pi-gateway/crowdsec-logs 2>/dev/null || mkdir -p /run/pi-gateway/crowdsec-logs 2>/dev/null || true
  sudo chmod 755 /run/pi-gateway/crowdsec-logs 2>/dev/null || true
  if [[ -f "${REMOTE_DIR}/config/crowdsec/acquis.yaml" ]]; then
    cp "${REMOTE_DIR}/config/crowdsec/acquis.yaml" "${CONFIG}/acquis.yaml" 2>/dev/null || true
  fi
  if [[ -f /etc/systemd/system/pi-gateway-crowdsec-journal.service ]]; then
    sudo systemctl enable --now pi-gateway-crowdsec-journal.service 2>/dev/null || true
  fi
}
ensure_lapi_listen_port
ensure_lapi_credentials
ensure_journal_feed

cd "${REMOTE_DIR}/compose"
docker compose --env-file ../.env --profile crowdsec up -d crowdsec

for _ in 1 2 3 4 5 6 7 8 9 10 11 12 13 14 15; do
  if docker exec crowdsec cscli lapi status >/dev/null 2>&1; then
    log "LAPI OK"
    docker exec crowdsec cscli metrics 2>/dev/null | head -3 || true
    exit 0
  fi
  sleep 4
done

log "HATA: CrowdSec LAPI hazir degil — elle: setup-crowdsec.sh --reset"
docker logs crowdsec --tail 15
exit 1
