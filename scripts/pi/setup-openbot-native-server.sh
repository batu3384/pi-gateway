#!/usr/bin/env bash
# OpenBot self-hosted native (Docker yok) — Hermes gibi host kullanıcısı.
set -euo pipefail
REMOTE_DIR="${REMOTE_DIR:-/home/${USER}/pi-gateway}"
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
OPENBOT_USER="${OPENBOT_USER:-${USER:-batu}}"
OPENBOT_DATA_ROOT="${OPENBOT_DATA_ROOT:-/mnt/ssd/openbot-native}"
OPENBOT_DISPLAY_SIZE="${OPENBOT_DISPLAY_SIZE:-1024x768}"
OPENBOT_SERVER_NAME="${OPENBOT_SERVER_NAME:-Heimdall}"
LEGACY_DOCKER_DATA="${LEGACY_DOCKER_DATA:-/mnt/ssd/openbot/data}"
INSTALL_URL="https://raw.githubusercontent.com/nightly-labs/openbot/main/scripts/install-server.sh"

log() { echo "[openbot-native] $*"; }
die() { log "HATA: $*"; exit 1; }

[[ "$(id -u)" -eq 0 ]] && die "sudo ile değil, ${OPENBOT_USER} olarak çalıştır; script içinde sudo kullanır"
id "$OPENBOT_USER" >/dev/null 2>&1 || die "kullanıcı yok: $OPENBOT_USER"

if docker ps -a --format '{{.Names}}' 2>/dev/null | grep -qx openbot; then
  log "Docker OpenBot hâlâ var — önce remove-openbot-docker.sh"
  REMOTE_DIR="$REMOTE_DIR" bash "${SCRIPT_DIR}/remove-openbot-docker.sh"
fi

if ! command -v openbot >/dev/null 2>&1; then
  log "Native OpenBot kuruluyor (arm64, kullanıcı=$OPENBOT_USER)"
  curl -fsSL "$INSTALL_URL" | sudo bash -s -- \
    --user "$OPENBOT_USER" --display-size "$OPENBOT_DISPLAY_SIZE"
else
  log "openbot zaten yüklü: $(openbot version 2>/dev/null || true)"
fi

sudo mkdir -p "/etc/systemd/system/openbot.service.d"
# 4GB Pi: DNS yığını her zaman öncelikli (OOMScoreAdjust=300; upstream -500'ü ez).
# MemoryMax=2200M OpenBot'un kendi host_memory_low (~1 GiB boşluk) eşiğini geçer, MemoryHigh=1800M yumuşak sınırlar.
sudo tee /etc/systemd/system/openbot.service.d/pi-gateway.conf >/dev/null <<EOF
[Service]
MemoryHigh=1800M
MemoryMax=2200M
MemorySwapMax=1024M
OOMScoreAdjust=300
EOF
# Saatlik otomatik güncelleme provider-runtimes sürüm uyumsuzluğu yaratabilir — kontrollü güncelleme kullan.
sudo systemctl disable --now openbot-update.timer 2>/dev/null || true
sudo systemctl daemon-reload

sudo systemctl stop openbot.service 2>/dev/null || true

bash "${SCRIPT_DIR}/fix-openbot-webrtc-dns.sh"

sudo install -d -o "$OPENBOT_USER" -g "$OPENBOT_USER" -m 755 "$OPENBOT_DATA_ROOT"
mkdir -p "${OPENBOT_DATA_ROOT}/config" "${OPENBOT_DATA_ROOT}/OpenBot"
if [[ -d "${LEGACY_DOCKER_DATA}/.config/OpenBot" ]]; then
  log "Docker verisinden taşınıyor → $OPENBOT_DATA_ROOT"
  rsync -a --delete \
    --exclude='core.*' \
    --exclude='*snip*.txt' \
    "${LEGACY_DOCKER_DATA}/.config/OpenBot/" "${OPENBOT_DATA_ROOT}/config/OpenBot/"
  [[ -d "${LEGACY_DOCKER_DATA}/OpenBot" ]] && \
    rsync -a "${LEGACY_DOCKER_DATA}/OpenBot/" "${OPENBOT_DATA_ROOT}/OpenBot/"
fi

# XDG: state SSD'de, SD kartta symlink
ob_home="$(getent passwd "$OPENBOT_USER" | cut -d: -f6)"
mkdir -p "${ob_home}/.config"
ln -sfn "${OPENBOT_DATA_ROOT}/config/OpenBot" "${ob_home}/.config/OpenBot"
if [[ -d "${OPENBOT_DATA_ROOT}/OpenBot" ]]; then
  ln -sfn "${OPENBOT_DATA_ROOT}/OpenBot" "${ob_home}/OpenBot" 2>/dev/null || true
fi

# .env
envf="${REMOTE_DIR}/.env"
touch "$envf"
for kv in \
  "OPENBOT_NATIVE=true" \
  "OPENBOT_USER=${OPENBOT_USER}" \
  "OPENBOT_DATA_ROOT=${OPENBOT_DATA_ROOT}" \
  "OPENBOT_STATE_DIR=${OPENBOT_DATA_ROOT}/config/OpenBot" \
  "OPENBOT_JARVIS=true" \
  "OPENBOT_JARVIS_AUTOMATION=true" \
  "NOTIFY_BACKEND=openbot" \
  "OPENBOT_SERVER_NAME=${OPENBOT_SERVER_NAME}"; do
  key="${kv%%=*}"
  if grep -q "^${key}=" "$envf" 2>/dev/null; then
    sed -i "s|^${key}=.*|${kv}|" "$envf"
  else
    echo "$kv" >>"$envf"
  fi
done

sudo systemctl enable --now openbot.service
sleep 8
sudo openbot status 2>/dev/null | head -20 || true

REMOTE_DIR="$REMOTE_DIR" OPENBOT_DATA_ROOT="$OPENBOT_DATA_ROOT" \
  bash "${SCRIPT_DIR}/setup-openbot-jarvis-migration.sh" \
  || log "WARN: jarvis migration atlandı (ilk kurulumda önce openbot login + setup-openbot-fleet.sh)"
REMOTE_DIR="$REMOTE_DIR" bash "${SCRIPT_DIR}/setup-openbot-jarvis-automation.sh" \
  || log "WARN: jarvis automation atlandı (setup-openbot-fleet.sh sonrası tekrarlayın)"
REMOTE_DIR="$REMOTE_DIR" bash "${SCRIPT_DIR}/repair-openbot-provider-runtimes.sh" \
  || log "WARN: provider-runtimes onarımı atlandı"

if command -v openbot >/dev/null && sudo openbot status 2>/dev/null | grep -q '^Account:.*@'; then
  sudo openbot name "$OPENBOT_SERVER_NAME" 2>/dev/null || true
fi
log "Giriş yoksa: sudo openbot login  (veya uygulamadan claim ile yeniden kur)"
log "Durum: sudo openbot status  |  journal: openbot logs -f"