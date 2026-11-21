#!/usr/bin/env bash
# Code deploy: repo sync + privileged lib + OpenBot/notify hot path.
# Skip: bootstrap, compose canary, UFW/CrowdSec full post-deploy.
# n8n: yalnız NODES_EXCLUDE henüz uygulanmadıysa recreate.
set -euo pipefail
REMOTE_DIR="${REMOTE_DIR:-/home/${USER}/pi-gateway}"
SCRIPT_DIR="${REMOTE_DIR}/scripts/pi"
log() { echo "[post-deploy-code] $*"; }

[[ -f "$REMOTE_DIR/.env" ]] || { log "HATA: .env yok"; exit 1; }
# shellcheck source=../lib/env-file.sh
source "${SCRIPT_DIR}/../lib/env-file.sh"
read_remote_dotenv || { log "HATA: .env parse"; exit 1; }

soft() {
  local name="$1" script="$2"
  log ">> $name"
  if REMOTE_DIR="$REMOTE_DIR" bash "$script"; then
    return 0
  fi
  log "WARN: $name basarisiz — devam"
  return 0
}

crit() {
  local name="$1" script="$2"
  log ">> $name"
  REMOTE_DIR="$REMOTE_DIR" bash "$script" || {
    log "HATA: $name"
    exit 1
  }
}

crit "Privileged scripts" "$SCRIPT_DIR/install-privileged-scripts.sh"
crit "DNS perf profile" "$SCRIPT_DIR/ensure-dns-perf-profile.sh"
crit "AdGuard wait" "$SCRIPT_DIR/wait-adguard-dns.sh"
crit "AdGuard DNS" "$SCRIPT_DIR/apply-adguard-dns.sh"
crit "AdGuard rewrites" "$SCRIPT_DIR/apply-adguard-rewrites.sh"
crit "AdGuard filters" "$SCRIPT_DIR/apply-adguard-filters.sh"
# Tek dosya bind mount + rsync rename = eski inode; restart yetmez, recreate sart
# (yoksa health unbound-stale-conf). Kisa kesinti AGH DoT fallback ile kapanir.
# shellcheck source=../lib/stack-health.sh
source "${SCRIPT_DIR}/../lib/stack-health.sh"
if unbound_conf_stale; then
  log ">> Unbound recreate (conf degisti)"
  (cd "$REMOTE_DIR/compose" && docker compose --env-file ../.env up -d --force-recreate --no-deps unbound) \
    || log "WARN: unbound recreate"
fi
sudo systemctl reset-failed pi-gateway-adguard-filters.service 2>/dev/null || \
  log "WARN: AdGuard filter failed state reset"
soft "IPv6 ULA DNS" "$SCRIPT_DIR/ensure-ipv6-ula.sh"
soft "IPv6 RDNSS RA" "$SCRIPT_DIR/setup-rdnss-ra.sh"
if [[ "${ENABLE_NETALERTX:-true}" == "true" ]] \
  && docker ps -a --format '{{.Names}}' 2>/dev/null | grep -qx netalertx; then
  log ">> NetAlertX compose (cpu/mem limit + db)"
  (cd "$REMOTE_DIR/compose" && docker compose --env-file ../.env \
    --profile netalert up -d --no-deps netalertx) \
    || log "WARN: NetAlertX compose up"
  soft "NetAlert DB" "$SCRIPT_DIR/ensure-netalert-db-access.sh"
  soft "NetAlertX setup" "$SCRIPT_DIR/setup-netalertx.sh"
fi
soft "Config izinleri" "$SCRIPT_DIR/fix-config-perms.sh"
soft "SSD SMART timer" "$SCRIPT_DIR/setup-ssd-smart-timer.sh"
soft "Restic repair" "$SCRIPT_DIR/restic-repair.sh"

if command -v tailscale >/dev/null 2>&1 && tailscale status >/dev/null 2>&1; then
  # setup-tailscale-serve.sh icinde setup-caddy-lan-ip.sh ve caddy reload zaten calisir
  soft "Tailscale panel HTTPS" "$SCRIPT_DIR/setup-tailscale-serve.sh"
elif [[ -n "${PI_STATIC_IP:-}" && -f "${REMOTE_DIR}/config/caddy/Caddyfile" ]]; then
  soft "LAN IP panel yollari" "$SCRIPT_DIR/setup-caddy-lan-ip.sh"
fi
if docker ps --format '{{.Names}}' 2>/dev/null | grep -qx n8n; then
  n8n_ex="$(docker inspect n8n --format '{{range .Config.Env}}{{println .}}{{end}}' 2>/dev/null | grep '^NODES_EXCLUDE=' || true)"
  if [[ "$n8n_ex" == *n8n-nodes-base.ssh* ]]; then
    log "n8n NODES_EXCLUDE zaten ssh kapali — recreate yok"
  else
    log ">> n8n recreate (NODES_EXCLUDE ssh)"
    (cd "$REMOTE_DIR/compose" && docker compose --env-file ../.env --profile n8n up -d --no-deps n8n) \
      || log "WARN: n8n up"
  fi
fi

if [[ -x "$SCRIPT_DIR/setup-openbot-fleet.sh" ]]; then
  log ">> OpenBot filo prompt + beceri senkronu"
  REMOTE_DIR="$REMOTE_DIR" bash "$SCRIPT_DIR/setup-openbot-fleet.sh" --files-only \
    || log "WARN: OpenBot filo dosya senkronu atlandi"
fi
OPENBOT_HEAL_QUICK=true soft "OpenBot heal" "$SCRIPT_DIR/heal-openbot-fleet.sh"

soft "Home ops timers" "$SCRIPT_DIR/setup-home-ops-timers.sh"
soft "Notify transition self-check" "$SCRIPT_DIR/test-notify-transitions.sh"
soft "Host sertlestirme" "$SCRIPT_DIR/harden-host.sh"
log "Code post-deploy tamamlandi"
