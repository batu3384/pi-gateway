#!/usr/bin/env bash
# Hermes gateway systemd: mutual exclusion with panel poller via HERMES_TELEGRAM_GATEWAY
set -euo pipefail
REMOTE_DIR="${REMOTE_DIR:-/home/${USER}/pi-gateway}"
log() { echo "[hermes-gateway-setup] $*"; }
die() { log "HATA: $*"; exit 1; }
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
_PG_ENV_LIB="${SCRIPT_DIR}/../lib/env-file.sh"
PG_SCRIPT_NAME="$(basename "$0")"
# shellcheck source=../lib/env-file.sh
source "${_PG_ENV_LIB:?}"
read_remote_dotenv || { echo "[${PG_SCRIPT_NAME}] HATA: .env dotenv parser hatasi" >&2; exit 1; }

unit=hermes-gateway.service
src="$REMOTE_DIR/host/systemd/$unit"
hermes_bin="${HOME}/.local/bin/hermes"
hermes_env="${HERMES_HOME:-$HOME/.hermes}/.env"
poller=pi-gateway-telegram-bot.service
# Restart=always: process up ≠ Telegram connected
STABLE_SECS="${HERMES_STABLE_SECS:-12}"
WAIT_SECS="${HERMES_WAIT_SECS:-60}"

_restore_poller() {
  [[ -f "$REMOTE_DIR/host/systemd/$poller" ]] || return 1
  load_telegram_from_hermes || true
  sudo cp "$REMOTE_DIR/host/systemd/$poller" "/etc/systemd/system/$poller"
  sudo sed -i "s|PI_USER|${USER}|g" "/etc/systemd/system/$poller" 2>/dev/null || \
    sudo sed -i '' "s|PI_USER|${USER}|g" "/etc/systemd/system/$poller" 2>/dev/null || true
  sudo systemctl daemon-reload
  sudo systemctl enable --now "$poller" 2>/dev/null || true
  log "Fallback: panel poller enable"
}

_hermes_telegram_connected() {
  # Exact success lines from patched telegram adapter (not "Connecting")
  journalctl -u "$unit" --since "3 min ago" -n 400 --no-pager 2>/dev/null \
    | grep -qE 'Connected to Telegram|polling_started=True'
}

# Rollback / poller mode: Hermes must not keep getUpdates
if [[ "${HERMES_TELEGRAM_GATEWAY:-}" != "true" ]]; then
  if [[ -f "$src" ]]; then
    sudo cp "$src" "/etc/systemd/system/$unit"
    sudo sed -i "s|PI_USER|${USER}|g" "/etc/systemd/system/$unit" 2>/dev/null || \
      sudo sed -i '' "s|PI_USER|${USER}|g" "/etc/systemd/system/$unit" 2>/dev/null || true
    sudo systemctl daemon-reload
  fi
  if systemctl list-unit-files "$unit" 2>/dev/null | grep -q "$unit"; then
    sudo systemctl disable --now "$unit" 2>/dev/null || true
    log "HERMES_TELEGRAM_GATEWAY!=true — $unit disabled"
  else
    log "HERMES_TELEGRAM_GATEWAY!=true — $unit yok, atlandi"
  fi
  exit 0
fi

# Cutover mode
[[ -f "$src" ]] || die "$src yok"
[[ -x "$hermes_bin" ]] || die "HERMES_TELEGRAM_GATEWAY=true ama hermes yok ($hermes_bin)"
[[ -f "$hermes_env" ]] || die "eksik $hermes_env (TELEGRAM_BOT_TOKEN + TELEGRAM_ALLOWED_USERS)"
grep -qE '^TELEGRAM_BOT_TOKEN=.+' "$hermes_env" || die "$hermes_env TELEGRAM_BOT_TOKEN bos"
grep -qE '^TELEGRAM_ALLOWED_USERS=.+' "$hermes_env" || die "$hermes_env TELEGRAM_ALLOWED_USERS bos (fail-closed allowlist)"

sudo cp "$src" "/etc/systemd/system/$unit"
sudo sed -i "s|PI_USER|${USER}|g" "/etc/systemd/system/$unit" 2>/dev/null || \
  sudo sed -i '' "s|PI_USER|${USER}|g" "/etc/systemd/system/$unit" 2>/dev/null || true

[[ -x "$SCRIPT_DIR/patch-hermes-telegram-pi.sh" ]] || die "patch-hermes-telegram-pi.sh yok"
bash "$SCRIPT_DIR/patch-hermes-telegram-pi.sh" || die "hermes telegram patch basarisiz — gateway enable yok"

# Poller once — dual getUpdates penceresi olmasin
if systemctl list-unit-files "$poller" 2>/dev/null | grep -q "$poller"; then
  sudo systemctl disable --now "$poller" || die "panel poller kapatilamadi (cift getUpdates riski)"
  log "Panel poller kapatildi (cutover)"
fi

sudo systemctl daemon-reload
sudo systemctl enable "$unit"
sudo systemctl restart "$unit"

stable=0
connected=0
for _ in $(seq 1 "$WAIT_SECS"); do
  if systemctl is-active --quiet "$unit"; then
    stable=$((stable + 1))
  else
    stable=0
  fi
  if [[ "$stable" -ge "$STABLE_SECS" ]] && _hermes_telegram_connected; then
    connected=1
    break
  fi
  sleep 1
done

if [[ "$connected" -ne 1 ]]; then
  log "HATA: $unit stabil/Connected degil — poller geri acilacak"
  _restore_poller || true
  sudo systemctl disable --now "$unit" 2>/dev/null || true
  die "$unit Telegram Connected yok — journalctl -u $unit"
fi
log "Aktif (Connected): $unit"
