#!/usr/bin/env bash
# OpenBot hosted-server (Chromium) 127.0.0.1 DNS üzerinden turn2 çözümleyemeyebilir (-105).
# /etc/hosts ile TURN adresi; mobil ↔ Heimdall WebRTC tüneli.
set -euo pipefail

MARKER="# pi-gateway-openbot-turn"
HOSTS_FILE="/etc/hosts"
TURN_HOST="turn2.openbot.run"

log() { echo "[openbot-webrtc-dns] $*"; }

[[ "$(id -u)" -eq 0 ]] && die() { log "HATA: $*"; exit 1; } || die() { log "HATA: $*"; exit 1; }

ip="$(dig +short "${TURN_HOST}" A 2>/dev/null | grep -E '^[0-9.]+$' | head -1)"
if [[ -z "$ip" ]]; then
  ip="$(getent ahostsv4 "${TURN_HOST}" 2>/dev/null | awk '{print $1; exit}')"
fi
[[ -n "$ip" ]] || die "TURN A kaydı yok: ${TURN_HOST}"

line="${ip} ${TURN_HOST} ${TURN_HOST}. ${MARKER}"
if grep -qF "$MARKER" "$HOSTS_FILE" 2>/dev/null; then
  sudo sed -i.bak-openbot-turn "/${MARKER//\//\\/}/c\\${line}" "$HOSTS_FILE"
else
  printf '%s\n' "$line" | sudo tee -a "$HOSTS_FILE" >/dev/null
fi
log "OK: ${TURN_HOST} -> ${ip}"