#!/usr/bin/env bash
# Hermes + Pi Telegram kalıntılarını kaldır (OpenBot Jarvis cutover sonrası).
set -euo pipefail
REMOTE_DIR="${REMOTE_DIR:-/home/${USER}/pi-gateway}"
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=../lib/env-file.sh
source "${SCRIPT_DIR}/../lib/env-file.sh"
read_remote_dotenv 2>/dev/null || true

log() { echo "[remove-hermes-telegram] $*"; }
die() { log "HATA: $*"; exit 1; }

BACKUP_ROOT="${PI_GATEWAY_BACKUP_DIR:-/mnt/ssd/pi-gateway-data/backups}"
STAMP="$(date +%Y%m%d-%H%M%S)"
RETIRE_ARCHIVE="${BACKUP_ROOT}/hermes-retired-${STAMP}.tar.gz"
HERMES_HOME="${HERMES_HOME:-$HOME/.hermes}"
ENV_FILE="${REMOTE_DIR}/.env"

[[ "${HERMES_TELEGRAM_GATEWAY:-false}" == "true" ]] \
  && die "HERMES_TELEGRAM_GATEWAY=true — önce false yap"

if systemctl is-active --quiet hermes-gateway 2>/dev/null; then
  die "hermes-gateway hâlâ active"
fi

mkdir -p "$BACKUP_ROOT"
_manifest=()
for f in \
  "${HERMES_HOME}/config.yaml" \
  "${HERMES_HOME}/cron/jobs.json" \
  "${HERMES_HOME}/SOUL.md" \
  "${HERMES_HOME}/.env"; do
  [[ -f "$f" ]] && _manifest+=("$f")
done
if ((${#_manifest[@]} > 0)); then
  tar -czf "$RETIRE_ARCHIVE" "${_manifest[@]}" || log "WARN: yedek arşivi başarısız"
  log "Yedek: $RETIRE_ARCHIVE (${#_manifest[@]} dosya)"
else
  log "Hermes yedeklenecek küçük dosya yok"
fi

for unit in hermes-gateway.service pi-gateway-telegram-bot.service; do
  if systemctl list-unit-files "$unit" 2>/dev/null | grep -q "$unit"; then
    sudo systemctl disable --now "$unit" 2>/dev/null || true
  fi
  sudo rm -f "/etc/systemd/system/${unit}" 2>/dev/null || true
done
sudo rm -rf /etc/systemd/system/hermes-gateway.service.d 2>/dev/null || true
sudo systemctl daemon-reload

rm -f "${HOME}/.local/bin/hermes" 2>/dev/null || true
if [[ -d "$HERMES_HOME" ]]; then
  log "Siliniyor: $HERMES_HOME ($(du -sh "$HERMES_HOME" 2>/dev/null | awk '{print $1}'))"
  rm -rf "$HERMES_HOME"
fi

if [[ -f "$ENV_FILE" ]]; then
  python3 - <<PY
from pathlib import Path
import re
p = Path("${ENV_FILE}")
lines = p.read_text().splitlines()
out = []
keys_drop = re.compile(
    r"^(TELEGRAM_|HERMES_|NOTIFY_HERMES_|GLM_API_KEY=)", re.I
)
for line in lines:
    raw = line.strip()
    if keys_drop.match(raw) and not raw.startswith("#") and "=" in raw:
        out.append("# retired-hermes: " + raw.split("=", 1)[0] + "=")
        continue
    out.append(line)
text = "\n".join(out) + "\n"
force = {
    "HERMES_TELEGRAM_GATEWAY": "false",
    "NOTIFY_BACKEND": "openbot",
    "NETALERTX_TELEGRAM_NEW_DEVICE": "false",
    "OPENBOT_JARVIS": "true",
    "OPENBOT_JARVIS_AUTOMATION": "true",
}
rewritten = []
seen = set()
for line in out:
    raw = line.strip()
    if not raw or raw.startswith("#") or "=" not in raw:
        rewritten.append(line)
        continue
    key = raw.split("=", 1)[0]
    if key in force:
        if key not in seen:
            rewritten.append(f"{key}={force[key]}")
            seen.add(key)
        continue
    rewritten.append(line)
    seen.add(key)
for k, v in force.items():
    if k not in seen:
        rewritten.append(f"{k}={v}")
out = rewritten
p.write_text("\n".join(out) + "\n")
print("env scrubbed:", p)
PY
fi

if [[ -x "${SCRIPT_DIR}/setup-openbot-jarvis-migration.sh" ]]; then
  REMOTE_DIR="$REMOTE_DIR" bash "${SCRIPT_DIR}/setup-openbot-jarvis-migration.sh" || log "WARN: openbot sync"
fi

if command -v crontab >/dev/null 2>&1; then
  crontab -l 2>/dev/null | grep -v hermes | crontab - 2>/dev/null || true
fi

log "Tamam — Hermes/Telegram Pi'den kaldırıldı."
log "Uyarılar: NOTIFY_BACKEND=openbot + OPENBOT_JARVIS_AUTOMATION=true → jarvis-send."
log "Bültenler: config/openbot/ROUTINES.md"