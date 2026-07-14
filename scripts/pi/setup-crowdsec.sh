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
