#!/usr/bin/env bash
# Pi Gateway deploy
#
# DEPLOY_MODE=full (default) — validate → rsync → bootstrap → compose → post-deploy → smoke
# DEPLOY_MODE=code           — validate → rsync → post-deploy-code (privileged + Hermes)
#   make deploy-code | make deploy-fast
#
# Full without image pull: DEPLOY_SKIP_PULL=true make deploy
# Code + smoke:            DEPLOY_SMOKE=true make deploy-code
set -euo pipefail
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=../lib/common.sh
source "$SCRIPT_DIR/../lib/common.sh"
load_env
PI_USER="${PI_USER:-pi}"
PI_HOST="${PI_HOST:-}"
REMOTE_DIR="${REMOTE_DIR:-/home/$PI_USER/pi-gateway}"
STORAGE_TYPE="${STORAGE_TYPE:-hybrid}"
PI_DEPLOY_HOST="${PI_DEPLOY_HOST:-}"
SSH_HOST="${PI_DEPLOY_HOST:-$PI_HOST}"
DEPLOY_MODE="${DEPLOY_MODE:-full}"
export PI_DEPLOY_HOST
[[ -n "$SSH_HOST" ]] || die "PI_HOST or PI_DEPLOY_HOST required"
case "$DEPLOY_MODE" in
  full|code) ;;
  *) die "DEPLOY_MODE=$DEPLOY_MODE — full|code" ;;
esac

"$SCRIPT_DIR/render-config.sh"
"$SCRIPT_DIR/validate.sh"
"$SCRIPT_DIR/pre-deploy-check.sh"
# shellcheck source=../lib/compose-profiles.sh
source "$SCRIPT_DIR/../lib/compose-profiles.sh"
load_compose_profiles
# shellcheck disable=SC2154
PROFILES=("${profiles[@]}")

log "Deploy mode=$DEPLOY_MODE -> $PI_USER@$SSH_HOST:$REMOTE_DIR"
ssh -o ConnectTimeout=15 "$PI_USER@$SSH_HOST" "mkdir -p '$REMOTE_DIR'"
rsync -avz --delete \
  --exclude '.git' \
  --exclude '.env' \
  --exclude 'data' \
  --exclude 'data.sd-degraded.bak*' \
  --filter 'protect data' \
  --filter 'protect data/**' \
  --filter 'protect data.sd-degraded.bak*' \
  --filter 'protect data.sd-degraded.bak*/**' \
  --filter 'protect config/homepage/logs' \
  --filter 'protect config/homepage/logs/**' \
  --exclude 'config/adguard/AdGuardHome.yaml' \
  --exclude 'config/homepage/services.yaml' \
  --exclude 'config/caddy/Caddyfile' \
  --exclude 'config/homepage/logs/**' \
  --exclude 'backups' \
  --exclude '*.bak' \
  --exclude 'legacy/' \
  "$PROJECT_DIR/" "$PI_USER@$SSH_HOST:$REMOTE_DIR/"
scp "$PROJECT_DIR/.env" "$PI_USER@$SSH_HOST:/tmp/pi-gateway.env.new"
ssh "$PI_USER@$SSH_HOST" "REMOTE_DIR='$REMOTE_DIR' bash -s" <<'ENVMERGE'
set -euo pipefail
R="${REMOTE_DIR}"
NEW="/tmp/pi-gateway.env.new"
OLD="${R}/.env"
OUT="${R}/.env"
PRESERVE='N8N_ENCRYPTION_KEY CROWDSEC_BOUNCER_KEY CROWDSEC_API_KEY HERMES_TELEGRAM_GATEWAY'
python3 - "$NEW" "$OLD" "$OUT" $PRESERVE <<'PY'
import sys
from pathlib import Path
new_path, old_path, out_path = Path(sys.argv[1]), Path(sys.argv[2]), Path(sys.argv[3])
preserve = set(sys.argv[4:])
def parse(path: Path) -> dict[str, str]:
    data = {}
    if not path.is_file():
        return data
    for line in path.read_text().splitlines():
        if not line or line.lstrip().startswith("#") or "=" not in line:
            continue
        k, _, v = line.partition("=")
        data[k.strip()] = v
    return data
new = parse(new_path)
old = parse(old_path)
for k in preserve:
    ov = old.get(k, "").strip()
    nv = new.get(k, "").strip()
    if ov and (not nv or nv.startswith("CHANGE_ME") or nv.startswith("Degistir")):
        new[k] = old[k]
lines = new_path.read_text().splitlines() if new_path.is_file() else []
out_lines = []
seen = set()
for line in lines:
    if line and not line.lstrip().startswith("#") and "=" in line:
        k = line.partition("=")[0].strip()
        seen.add(k)
        if k in new:
            out_lines.append(f"{k}={new[k]}")
            continue
    out_lines.append(line)
for k in preserve:
    if k in new and k not in seen:
        out_lines.append(f"{k}={new[k]}")
out_path.write_text("\n".join(out_lines) + "\n")
print(f"[env-merge] preserved={','.join(sorted(preserve & set(old))) or 'none'}")
PY
rm -f "$NEW"
ENVMERGE
"$SCRIPT_DIR/sync-rendered-configs.sh" || log "WARN: rendered config sync atlandi"

DEPLOY_HOST="${PI_DEPLOY_HOST:-${PI_STATIC_IP:-$PI_HOST}}"

finish_urls() {
  DOMAIN="${LAN_DOMAIN:-home}"
  log "Deploy complete (mode=$DEPLOY_MODE)"
  log "  Gateway : https://gateway.${DOMAIN}"
  log "  Status  : https://status.${DOMAIN}"
  log "  Logs    : https://logs.${DOMAIN}"
  log "  DNS     : https://dns.${DOMAIN}"
  log "  n8n     : https://n8n.${DOMAIN}"
  log "  UFW     : ${UFW_ADMIN_EXPOSURE:-caddy-only}"
  if [[ "${NETWORK_MODE:-router-dns}" == "router-dns" ]]; then
    log "  ACTION  : Router DNS -> ${PI_STATIC_IP:-$PI_HOST}"
  else
    log "  ACTION  : Router DHCP OFF; AdGuard DHCP active"
  fi
}

# --- code path: no bootstrap / canary / full post-deploy ---
if [[ "$DEPLOY_MODE" == "code" ]]; then
  log "Code path: privileged + Hermes/notify (bootstrap/canary/UFW skip)"
  ssh -o ConnectTimeout=20 "$PI_USER@$DEPLOY_HOST" \
    "chmod +x '$REMOTE_DIR/scripts/pi/post-deploy-code.sh' && REMOTE_DIR='$REMOTE_DIR' bash '$REMOTE_DIR/scripts/pi/post-deploy-code.sh'"
  if [[ "${DEPLOY_SMOKE:-false}" == "true" ]]; then
    ssh "$PI_USER@$DEPLOY_HOST" "REMOTE_DIR='$REMOTE_DIR' bash '$REMOTE_DIR/scripts/pi/smoke-test.sh'"
  else
    log "Smoke atlandi (DEPLOY_SMOKE=true ile ac)"
  fi
  finish_urls
  exit 0
fi

# --- full path ---
ssh "$PI_USER@$SSH_HOST" "REMOTE_DIR='$REMOTE_DIR' bash '$REMOTE_DIR/scripts/pi/bootstrap.sh'"
wait_ssh() {
  local host="$1" tries="${2:-24}" i
  for ((i = 1; i <= tries; i++)); do
    if ssh -o ConnectTimeout=5 -o BatchMode=yes -o StrictHostKeyChecking=accept-new \
      "$PI_USER@$host" 'true' 2>/dev/null; then
      log "SSH ready: $PI_USER@$host (attempt $i)"
      return 0
    fi
    sleep 5
  done
  die "SSH failed after dhcpcd/bootstrap: $PI_USER@$host — need working SSH key (ssh-copy-id); password-only auth not supported for deploy"
}
log "Waiting for SSH on deploy host ($DEPLOY_HOST) after bootstrap..."
wait_ssh "$DEPLOY_HOST"
PROFILE_ARGS="${PROFILES[*]}"
COMPOSE_MODE="$(ssh -o ConnectTimeout=20 "$PI_USER@$DEPLOY_HOST" \
  "REMOTE_DIR='$REMOTE_DIR' bash -s" <<'REMOTE_EOF'
set -euo pipefail
source "$REMOTE_DIR/scripts/lib/env-file.sh"
read_remote_dotenv || exit 1
source "$REMOTE_DIR/scripts/lib/stack-health.sh"
if ! needs_ssd_storage; then
  echo full
  exit 0
fi
if storage_degraded || ! ssd_mount_healthy; then
  echo core-dns
else
  echo full
fi
REMOTE_EOF
)" || die "SSH compose mode probe failed: $PI_USER@$DEPLOY_HOST"
COMPOSE_MODE="$(echo "$COMPOSE_MODE" | tr -d '\r' | tail -1)"
case "$COMPOSE_MODE" in
  full|core-dns) ;;
  *)
    log "WARN: COMPOSE_MODE='$COMPOSE_MODE' gecersiz — core-dns"
    COMPOSE_MODE="core-dns"
    ;;
esac
if [[ "$COMPOSE_MODE" == "core-dns" ]]; then
  log "SSD yok/degraded — compose core-dns (unbound+adguard; caddy opsiyonel)"
  core_pull=(unbound adguard)
  [[ "${ENABLE_CADDY:-true}" == "true" ]] && core_pull+=(homepage caddy)
  if [[ "${DEPLOY_SKIP_PULL:-false}" != "true" ]]; then
    ssh -o ConnectTimeout=20 "$PI_USER@$DEPLOY_HOST" \
      "cd '$REMOTE_DIR/compose' && docker compose --env-file ../.env --profile caddy pull ${core_pull[*]}" \
      || log "WARN: core-dns pull kismi"
  fi
  ssh -o ConnectTimeout=20 "$PI_USER@$DEPLOY_HOST" \
    "REMOTE_DIR='$REMOTE_DIR' COMPOSE_RECOVER_MODE=core-dns bash '$REMOTE_DIR/scripts/pi/recover-compose-up.sh'"
else
  if [[ "${DEPLOY_SKIP_PULL:-false}" == "true" ]]; then
    log "canary compose up (pull skipped — DEPLOY_SKIP_PULL=true)"
    ssh -o ConnectTimeout=20 "$PI_USER@$DEPLOY_HOST" \
      "REMOTE_DIR='$REMOTE_DIR' DEPLOY_SKIP_PULL=true bash '$REMOTE_DIR/scripts/pi/canary-compose-update.sh'"
  elif [[ "${ENABLE_CANARY_COMPOSE_UPDATE:-true}" == "true" ]]; then
    log "canary compose update (DNS -> edge -> rest)"
    ssh -o ConnectTimeout=20 "$PI_USER@$DEPLOY_HOST" \
      "REMOTE_DIR='$REMOTE_DIR' bash '$REMOTE_DIR/scripts/pi/canary-compose-update.sh'"
  else
    ssh -o ConnectTimeout=20 "$PI_USER@$DEPLOY_HOST" "cd '$REMOTE_DIR/compose' && docker compose --env-file ../.env $PROFILE_ARGS pull && docker compose --env-file ../.env $PROFILE_ARGS up -d --remove-orphans && docker compose --env-file ../.env $PROFILE_ARGS up -d --force-recreate unbound"
  fi
fi

# Sabit sleep yerine DNS settle (erken cikis)
SETTLE="${DEPLOY_POST_COMPOSE_WAIT_SEC:-12}"
if (( SETTLE > 0 )); then
  log "Compose settle (max ${SETTLE}s, DNS hazirsa erken)..."
  ssh -o ConnectTimeout=20 "$PI_USER@$DEPLOY_HOST" \
    "REMOTE_DIR='$REMOTE_DIR' SETTLE='$SETTLE' bash -s" <<'SETTLE_EOF'
set -euo pipefail
max="${SETTLE:-12}"
ip="${PI_STATIC_IP:-127.0.0.1}"
# shellcheck source=/dev/null
source "$REMOTE_DIR/scripts/lib/env-file.sh" 2>/dev/null || true
read_remote_dotenv 2>/dev/null || true
ip="${PI_STATIC_IP:-$ip}"
end=$((SECONDS + max))
while (( SECONDS < end )); do
  if command -v dig >/dev/null 2>&1 \
    && dig +time=1 +tries=1 "@${ip}" cloudflare.com A +short 2>/dev/null | grep -qE '^[0-9.]+$'; then
    echo "[settle] DNS OK (${SECONDS}s)"
    exit 0
  fi
  sleep 2
done
echo "[settle] timeout ${max}s — devam"
SETTLE_EOF
fi

ssh "$PI_USER@$DEPLOY_HOST" "REMOTE_DIR='$REMOTE_DIR' bash '$REMOTE_DIR/scripts/pi/post-deploy.sh'"
ssh "$PI_USER@$DEPLOY_HOST" "REMOTE_DIR='$REMOTE_DIR' bash '$REMOTE_DIR/scripts/pi/smoke-test.sh'"
finish_urls
