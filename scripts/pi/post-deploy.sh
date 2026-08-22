#!/usr/bin/env bash
# Deploy sonrasi tum yapilandirmalari sirayla uygular
set -euo pipefail
REMOTE_DIR="${REMOTE_DIR:-/home/${USER}/pi-gateway}"
SCRIPT_DIR="${REMOTE_DIR}/scripts/pi"
DEPLOY_STRICT="${DEPLOY_STRICT:-true}"
log() { echo "[post-deploy] $*"; }
run_step_critical() {
  local name="$1" script="$2"
  log ">> $name"
  REMOTE_DIR="$REMOTE_DIR" bash "$script" || {
    log "HATA: $name basarisiz"
    exit 1
  }
}
run_step_optional() {
  local name="$1" script="$2"
  log ">> $name"
  if REMOTE_DIR="$REMOTE_DIR" bash "$script"; then
    return 0
  fi
  if [[ "$DEPLOY_STRICT" == "true" ]]; then
    log "HATA: $name basarisiz (DEPLOY_STRICT=true)"
    exit 1
  fi
  log "WARN: $name atlandi"
}
# Backup asla deploy'u durdurmaz (DEPLOY_STRICT olsa bile)
run_step_soft() {
  local name="$1" script="$2"
  log ">> $name"
  if REMOTE_DIR="$REMOTE_DIR" bash "$script"; then
    return 0
  fi
  log "WARN: $name basarisiz — deploy devam"
  return 0
}
[[ -f "$REMOTE_DIR/.env" ]] || { log "HATA: .env yok"; exit 1; }
_PG_ENV_LIB="${SCRIPT_DIR:-$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)}/../lib/env-file.sh"
PG_SCRIPT_NAME="$(basename "$0")"
# shellcheck source=../lib/env-file.sh
source "${_PG_ENV_LIB:?}"
read_remote_dotenv || { echo "[${PG_SCRIPT_NAME:-script}] HATA: .env dotenv parser hatasi" >&2; exit 1; }
DEPLOY_DEGRADED=0
if [[ -f /run/pi-gateway/storage-degraded ]]; then
  DEPLOY_DEGRADED=1
fi
# shellcheck source=../lib/stack-health.sh
if [[ "$DEPLOY_DEGRADED" -eq 0 ]] && [[ -f "$REMOTE_DIR/scripts/lib/stack-health.sh" ]]; then
  source "$REMOTE_DIR/scripts/lib/stack-health.sh"
  storage_degraded && DEPLOY_DEGRADED=1
fi
if [[ "$DEPLOY_DEGRADED" -eq 1 ]]; then
  log "WARN: storage degraded — yalnizca DNS/firewall post-deploy (app setup atlanir)"
fi
for key in AGH_ADMIN_PASSWORD DOZZLE_ADMIN_PASSWORD RESTIC_PASSWORD FORGEJO_ADMIN_PASSWORD N8N_WEBHOOK_SECRET UPTIME_KUMA_ADMIN_PASSWORD SYNCTHING_GUI_PASSWORD REDIS_PASSWORD; do
  val="${!key:-}"
  case "$val" in
    ""|CHANGE_ME*|Degistir*)
      if [[ "$key" == "DOZZLE_ADMIN_PASSWORD" && "${ENABLE_DOZZLE:-true}" != "true" ]]; then
        continue
      fi
      if [[ "$key" == "RESTIC_PASSWORD" && "${ENABLE_RESTIC:-true}" != "true" ]]; then
        continue
      fi
      if [[ "$key" == "FORGEJO_ADMIN_PASSWORD" && "${ENABLE_FORGEJO:-true}" != "true" ]]; then
        continue
      fi
      if [[ "$key" == "N8N_WEBHOOK_SECRET" && "${ENABLE_N8N:-true}" != "true" ]]; then
        continue
      fi
      # Uptime Kuma is always deployed (no compose profile) — never skip on ENABLE_N8N
      if [[ "$key" == "SYNCTHING_GUI_PASSWORD" && "${ENABLE_SYNCTHING:-true}" != "true" ]]; then
        continue
      fi
      if [[ "$key" == "REDIS_PASSWORD" && "${ENABLE_REDIS:-false}" != "true" ]]; then
        continue
      fi
      log "HATA: $key bos veya placeholder — .env duzelt"
      exit 1
      ;;
  esac
done
run_step_critical "Privileged scripts (root-owned)" "$SCRIPT_DIR/install-privileged-scripts.sh"
run_step_optional "Config izinleri" "$SCRIPT_DIR/fix-config-perms.sh"
if [[ "$STORAGE_TYPE" == "hybrid" || "$STORAGE_TYPE" == "ssd-data" ]]; then
  run_step_optional "SSD fstab" "$SCRIPT_DIR/ensure-ssd-fstab.sh"
  log ">> SSD veri diski"
  ssd_env=(REMOTE_DIR="$REMOTE_DIR" STORAGE_TYPE="$STORAGE_TYPE" PI_USER="${PI_USER:-$USER}")
  if [[ ! -f /mnt/ssd/.pi-gateway-initialized ]]; then
    ssd_env+=(PI_SSD_CONFIRM_FORMAT=yes)
  fi
  if sudo env "${ssd_env[@]}" bash "$SCRIPT_DIR/setup-ssd-data.sh"; then
    log "SSD veri diski hazir"
  else
    if [[ "${DNS_DEGRADED_ON_SSD_LOSS:-true}" == "true" || "${STORAGE_FALLBACK_SD:-false}" == "true" ]]; then
      log "WARN: SSD yok — DNS degraded (SD data) ile devam"
      mkdir -p /run/pi-gateway 2>/dev/null || sudo mkdir -p /run/pi-gateway
      touch /run/pi-gateway/storage-degraded 2>/dev/null || sudo touch /run/pi-gateway/storage-degraded || true
      DEPLOY_DEGRADED=1
    else
      log "HATA: SSD veri diski hazirlanamadi (takili mi? PI_SSD_CONFIRM_FORMAT=yes)"
      exit 1
    fi
  fi
  log ">> SSD data symlink"
  REMOTE_DIR="$REMOTE_DIR" STORAGE_TYPE="$STORAGE_TYPE" bash "$SCRIPT_DIR/ensure-data-symlink.sh" repair || {
    if [[ "${DNS_DEGRADED_ON_SSD_LOSS:-true}" == "true" || "${STORAGE_FALLBACK_SD:-false}" == "true" ]]; then
      log "WARN: data symlink — degraded SD data ile devam"
      DEPLOY_DEGRADED=1
    else
      log "HATA: data symlink onarilamadi"
      exit 1
    fi
  }
  # SSD adimi sirasinda bayrak set edildiyse app setup atla
  if [[ -f /run/pi-gateway/storage-degraded ]]; then
    DEPLOY_DEGRADED=1
  fi
  if [[ "$DEPLOY_DEGRADED" -eq 1 ]]; then
    log "WARN: storage degraded — yalnizca DNS/firewall post-deploy (app setup atlanir)"
    run_step_critical "Docker SD fallback (degraded)" "$SCRIPT_DIR/setup-docker-fallback.sh"
  fi
elif [[ "$STORAGE_TYPE" == "ssd-root" || "$STORAGE_TYPE" == "ssd" ]]; then
  log ">> Native data dizini (ssd-root)"
  REMOTE_DIR="$REMOTE_DIR" STORAGE_TYPE="$STORAGE_TYPE" bash "$SCRIPT_DIR/ensure-data-symlink.sh" repair || {
    log "HATA: data dizini hazirlanamadi"
    exit 1
  }
  ROOT_SRC="$(findmnt -n -o SOURCE / 2>/dev/null || true)"
  if echo "$ROOT_SRC" | grep -q mmcblk; then
    log "HATA: ssd-root bekleniyor ama root SD ($ROOT_SRC)"
    exit 1
  fi
  run_step_critical "ssd-root harden" env REMOTE_DIR="$REMOTE_DIR" CONFIRM_NEUTRALIZE="${CONFIRM_NEUTRALIZE:-}" CONFIRM_EEPROM_FIX="${CONFIRM_EEPROM_FIX:-}" "$SCRIPT_DIR/ssd-root-harden.sh"
fi
run_step_critical "AdGuard yapilandirma" "$SCRIPT_DIR/configure-adguard.sh"
run_step_optional "AdGuard filter timer" "$SCRIPT_DIR/setup-adguard-timers.sh"
run_step_optional "IPv6 ULA DNS" "$SCRIPT_DIR/ensure-ipv6-ula.sh"
run_step_optional "IPv6 RDNSS RA" "$SCRIPT_DIR/setup-rdnss-ra.sh"
# shellcheck source=../lib/unified-login.sh
source "$SCRIPT_DIR/../lib/unified-login.sh"
apply_unified_login
if [[ "${UNIFIED_LOGIN:-true}" == "true" ]]; then
  run_step_critical "Servis sifreleri (unified login)" "$SCRIPT_DIR/sync-service-passwords.sh"
elif [[ "${SYNC_SERVICE_PASSWORDS:-false}" == "true" ]]; then
  run_step_optional "Servis sifreleri" "$SCRIPT_DIR/sync-service-passwords.sh"
fi
run_step_optional "Host sertlestirme" "$SCRIPT_DIR/harden-host.sh"
if [[ "$DEPLOY_DEGRADED" -eq 0 ]]; then
if [[ "${ENABLE_MONITORING:-true}" == "true" ]]; then
  run_step_critical "Monitoring data dirs" "$SCRIPT_DIR/ensure-monitoring-data.sh"
  run_step_optional "Monitoring stack restart" bash -c \
    'cd "'"$REMOTE_DIR"'/compose" && docker compose --env-file ../.env --profile monitoring up -d prometheus grafana node-exporter'
fi
if [[ "${ENABLE_FORGEJO:-true}" == "true" ]]; then
  run_step_optional "Forgejo admin" "$SCRIPT_DIR/setup-forgejo.sh"
fi
if [[ "${ENABLE_SYNCTHING:-true}" == "true" ]] && docker ps --format '{{.Names}}' | grep -q '^syncthing$'; then
  run_step_critical "Syncthing GUI auth" "$SCRIPT_DIR/setup-syncthing-auth.sh"
  run_step_optional "Syncthing eslestirme" "$SCRIPT_DIR/setup-syncthing.sh"
  DEVICE_ID="$(docker exec syncthing cat /var/syncthing/config/config.xml 2>/dev/null | sed -n 's:.*<device id="\([^"]*\)".*:\1:p' | head -1 || true)"
  log "Syncthing Pi Device ID: ${DEVICE_ID:-bilinmiyor}"
  log "Syncthing UI: http://sync.${LAN_DOMAIN:-home}"
fi
if [[ "${ENABLE_RESTIC:-true}" == "true" ]]; then
  run_step_soft "Restic yedek" "$SCRIPT_DIR/restic-backup.sh"
fi
if [[ "${ENABLE_DOZZLE:-true}" == "true" ]]; then
  run_step_critical "Dozzle auth" "$SCRIPT_DIR/setup-dozzle.sh"
fi
if [[ "${ENABLE_N8N:-true}" == "true" ]]; then
  run_step_critical "n8n encryption key" "$SCRIPT_DIR/ensure-n8n-encryption-key.sh"
  run_step_optional "Sabah ozeti timer" "$SCRIPT_DIR/setup-morning-timer.sh"
  run_step_critical "n8n otomasyonlar" "$SCRIPT_DIR/setup-n8n-workflows.sh"
fi
if [[ "${ENABLE_NETALERTX:-true}" == "true" ]]; then
  run_step_critical "NetAlertX ag envanteri" "$SCRIPT_DIR/setup-netalertx.sh"
fi
if docker ps --format '{{.Names}}' | grep -q '^uptime-kuma$'; then
  run_step_critical "Uptime Kuma monitorler" "$SCRIPT_DIR/setup-uptime-kuma.sh"
fi
if [[ "${ENABLE_N8N:-true}" == "true" ]] && [[ "${ENABLE_FORGEJO:-true}" == "true" ]]; then
  run_step_critical "Forgejo n8n webhook" "$SCRIPT_DIR/setup-forgejo-webhook.sh"
fi
if command -v tailscale >/dev/null 2>&1 && tailscale status >/dev/null 2>&1; then
  run_step_optional "Tailscale uzaktan erisim" "$SCRIPT_DIR/setup-tailscale-remote.sh"
  run_step_optional "Tailscale panel HTTPS" "$SCRIPT_DIR/setup-tailscale-serve.sh"
  run_step_optional "Tailscale ACL" "$SCRIPT_DIR/setup-tailscale-acl.sh"
fi
# LAN IP panel yollari (Tailscale yoksa da)
if [[ -n "${PI_STATIC_IP:-}" && -f "${REMOTE_DIR}/config/caddy/Caddyfile" ]]; then
  run_step_optional "LAN IP panel yollari" "$SCRIPT_DIR/setup-caddy-lan-ip.sh"
fi
run_step_soft "Telegram panel bot" "$SCRIPT_DIR/setup-telegram-bot.sh"
if [[ "${ENABLE_CROWDSEC:-true}" == "true" ]]; then
  run_step_optional "CrowdSec" "$SCRIPT_DIR/setup-crowdsec.sh"
  run_step_optional "CrowdSec firewall bouncer" "$SCRIPT_DIR/setup-crowdsec-bouncer.sh"
fi
fi
if [[ "${ENABLE_UFW:-true}" == "true" ]]; then
  run_step_critical "UFW firewall" "$SCRIPT_DIR/setup-firewall.sh"
fi
if [[ "$DEPLOY_DEGRADED" -eq 0 ]]; then
  if [[ "$STORAGE_TYPE" == "hybrid" || "$STORAGE_TYPE" == "ssd-data" ]]; then
    if [[ "${ENABLE_DOCKER_SSD:-false}" == "true" ]]; then
      if [[ ! -f /mnt/ssd/.docker-data-root ]] || [[ ! -f /etc/systemd/system/docker.service.d/pi-gateway-ssd.conf ]]; then
        run_step_optional "Docker SSD tasima" "$SCRIPT_DIR/setup-docker-ssd.sh"
      fi
    fi
  fi
  run_step_optional "SLO push monitors" "$SCRIPT_DIR/setup-slo-monitors.sh"
  run_step_optional "SSD SMART timer" "$SCRIPT_DIR/setup-ssd-smart-timer.sh"
  run_step_critical "Post-deploy integration" "$SCRIPT_DIR/post-deploy-integration.sh"
fi
log "Post-deploy tamamlandi"
