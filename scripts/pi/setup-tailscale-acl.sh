#!/usr/bin/env bash
# Tailscale ACL: yalnizca group:owners -> Pi ve ev LAN
set -euo pipefail

REMOTE_DIR="${REMOTE_DIR:-/home/${USER}/pi-gateway}"
ACL_FILE="${REMOTE_DIR}/config/tailscale/acl.hujson"
ACL_OWNER="${TAILSCALE_ACL_OWNER:-batu3384@gmail.com}"
API_KEY="${TAILSCALE_API_KEY:-}"

log() { echo "[tailscale-acl] $*"; }

command -v tailscale >/dev/null 2>&1 || { log "tailscale yok"; exit 0; }
[[ -f "$ACL_FILE" ]] || { log "ACL dosyasi yok: $ACL_FILE"; exit 1; }

if [[ -n "$API_KEY" ]]; then
  tailnet="$(tailscale status --json 2>/dev/null | python3 -c "
import json,sys
d=json.load(sys.stdin)
name=d.get('CurrentTailnet',{}).get('Name','')
print(name.split('@')[0] if '@' in name else name.replace('.ts.net',''))
" 2>/dev/null || true)"
  [[ -n "$tailnet" ]] || { log "HATA: tailnet adi alinamadi (tailscale status)"; exit 1; }
  log "API ile gonderiliyor (tailnet: $tailnet)..."
  if curl -fsS -X POST "https://api.tailscale.com/api/v2/tailnet/${tailnet}/acl" \
    -u "${API_KEY}:" \
    -H "Content-Type: application/json" \
    --data-binary @"$ACL_FILE"; then
    log "ACL uygulandi"
    exit 0
  fi
  log "WARN: API basarisiz — manuel yapistir"
fi

log ""
log "=== Manuel (bir kez) ==="
log "1) https://login.tailscale.com/admin/acls"
log "2) Asagidaki dosyanin icerigini yapistir:"
log "   $ACL_FILE"
log "3) Save"
log ""
log "Sahip: $ACL_OWNER — Tailnet'teki diger hesaplar Pi'ye erisemez."
log "Not: Bu interneti kapatmaz; yalnizca Tailscale agindaki kimlerin erisebilecegini belirler."
