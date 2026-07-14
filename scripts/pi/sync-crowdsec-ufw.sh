#!/usr/bin/env bash
# CrowdSec aktif kararlarini UFW kurallarina yansitir
set -euo pipefail

REMOTE_DIR="${REMOTE_DIR:-/home/${USER}/pi-gateway}"

docker ps --format '{{.Names}}' | grep -q '^crowdsec$' || exit 0

while read -r ip; do
  [[ -n "$ip" ]] || continue
  sudo ufw status | grep -qF "$ip" && continue
  sudo ufw deny from "$ip" comment "crowdsec" 2>/dev/null || true
done < <(docker exec crowdsec cscli decisions list -o raw 2>/dev/null | awk '{print $1}' | grep -E '^[0-9]+\.' || true)
