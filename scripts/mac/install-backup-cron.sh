#!/usr/bin/env bash
# Mac: haftalik backup-pull icin launchd agent kurar
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=../lib/common.sh
source "$SCRIPT_DIR/../lib/common.sh"
load_env

LABEL="com.pi-gateway.backup-pull"
PLIST="$HOME/Library/LaunchAgents/${LABEL}.plist"
BACKUP_SCRIPT="$PROJECT_DIR/scripts/mac/backup-pull.sh"
LOG_DIR="$HOME/Library/Logs/pi-gateway"
SCHEDULE_WEEKDAY="${BACKUP_CRON_WEEKDAY:-0}"
SCHEDULE_HOUR="${BACKUP_CRON_HOUR:-3}"

log() { echo "[backup-cron] $*"; }

[[ -x "$BACKUP_SCRIPT" ]] || chmod +x "$BACKUP_SCRIPT"
mkdir -p "$LOG_DIR" "$(dirname "$PLIST")"

cat > "$PLIST" <<EOF
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
  <key>Label</key>
  <string>${LABEL}</string>
  <key>ProgramArguments</key>
  <array>
    <string>/bin/bash</string>
    <string>${BACKUP_SCRIPT}</string>
  </array>
  <key>StartCalendarInterval</key>
  <dict>
    <key>Weekday</key>
    <integer>${SCHEDULE_WEEKDAY}</integer>
    <key>Hour</key>
    <integer>${SCHEDULE_HOUR}</integer>
    <key>Minute</key>
    <integer>0</integer>
  </dict>
  <key>StandardOutPath</key>
  <string>${LOG_DIR}/backup-pull.log</string>
  <key>StandardErrorPath</key>
  <string>${LOG_DIR}/backup-pull.err</string>
  <key>RunAtLoad</key>
  <false/>
</dict>
</plist>
EOF

launchctl bootout "gui/$(id -u)/${LABEL}" 2>/dev/null || true
launchctl bootstrap "gui/$(id -u)" "$PLIST"
launchctl enable "gui/$(id -u)/${LABEL}" 2>/dev/null || true

log "Kuruldu: Pazar ${SCHEDULE_HOUR}:00 (Weekday=${SCHEDULE_WEEKDAY})"
log "Log: ${LOG_DIR}/backup-pull.log"
log "Manuel test: make backup-pull"
