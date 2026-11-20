#!/usr/bin/env bash
# Heimdall durum kartı. stdout. LLM yok.
set -euo pipefail
echo "Heimdall · durum"
date '+%d.%m.%Y · %H:%M %Z'
echo
echo "Çalışma"
uptime -p 2>/dev/null || uptime
echo
echo "Bellek"
free -h | awk 'NR==2 {print $0}'
echo
echo "Disk"
df -hP / /mnt/ssd 2>/dev/null | awk 'NR>1 {print $6, $5, "dolu"}'
echo
echo "Servis"
if command -v docker >/dev/null 2>&1; then
  docker ps --format '{{.Names}} {{.Status}}' 2>/dev/null | head -n 25 \
    || echo "docker erişilemedi"
else
  echo "docker yok"
fi
echo
echo "Hata"
failed="$(systemctl --failed --no-legend --plain 2>/dev/null | awk '{print $1}' | head -n 15 || true)"
if [[ -n "${failed:-}" ]]; then
  printf '%s\n' "$failed"
else
  echo "yok"
fi
