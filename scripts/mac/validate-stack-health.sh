#!/usr/bin/env bash
# Kurtarma/watchdog mantik kontrolleri (regresyon onleme)
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROJECT_DIR="$(cd "$SCRIPT_DIR/../.." && pwd)"

die() { echo "[validate-stack] HATA: $*" >&2; exit 1; }
ok() { echo "[validate-stack] OK: $*"; }

watchdog="$PROJECT_DIR/scripts/pi/stack-watchdog.sh"
stack_health="$PROJECT_DIR/scripts/lib/stack-health.sh"
recover="$PROJECT_DIR/scripts/pi/recover-readonly-root.sh"
compose="$PROJECT_DIR/compose/docker-compose.yml"
compose_up="$PROJECT_DIR/scripts/pi/recover-compose-up.sh"

[[ -f "$watchdog" ]] || die "stack-watchdog.sh yok"
[[ -f "$stack_health" ]] || die "stack-health.sh yok"
[[ -f "$recover" ]] || die "recover-readonly-root.sh yok"

if grep -q 'is-active.*pi-gateway-recover-ro' "$watchdog"; then
  die "stack-watchdog hala is-active ile recover kontrol ediyor"
fi
ok "watchdog is-active regresyonu yok"

grep -q 'recover-readonly-root.sh' "$stack_health" \
  || die "trigger_stack_recover recover scriptini cagirmiyor"
ok "trigger_stack_recover script tabanli"

grep -q 'flock -w' "$stack_health" \
  || die "stack-health flock -w kullanmiyor"
ok "flock bekleme var"

grep -q 'stack_core_ok' "$stack_health" \
  || die "stack_core_ok yok — invert return code tuzagi geri gelebilir"
if grep -q 'stack_core_broken' "$stack_health" "$recover" 2>/dev/null; then
  die "stack_core_broken hala kullaniliyor — stack_core_ok kullan"
fi
ok "stack_core_ok kontrakti"

grep -A25 '^stack_core_ok()' "$stack_health" | grep -q 'return 0' \
  || die "stack_core_ok basari yolu return 0 icermiyor"
ok "stack_core_ok basari return 0"

# Davranis: docker/adguard yokken stack_core_ok 1 donmeli
if bash -c "REMOTE_DIR=/tmp source '$stack_health'; stack_core_ok"; then
  die "stack_core_ok Mac/CI ortaminda 0 dondu — kontrakt bozuk"
fi
ok "stack_core_ok bozuk ortamda fail"

grep -q 'STACK_RECOVER_WAIT_SEC:-300' "$stack_health" \
  || die "STACK_RECOVER_WAIT_SEC default 300 degil"
grep -q 'TimeoutStartSec=300' "$PROJECT_DIR/host/systemd/pi-gateway-recover-ro.service" \
  || die "recover-ro TimeoutStartSec 300 degil"
ok "recover wait/timeout 300s hizali"

grep -q 'apply_adguard_rewrites_best_effort' "$recover" \
  || die "recover rewrite best-effort cagirmiyor"
grep -A3 'Stack zaten saglikli' "$recover" | grep -q 'apply_adguard_rewrites' \
  || die "early healthy exit rewrite uygulamıyor"
ok "recover rewrite early+success yollari"

grep -q 'pi_user_from_remote_dir' "$stack_health" \
  || die "lock owner pi_user_from_remote_dir kullanmiyor"
if grep -q 'SUDO_USER:-batu' "$stack_health"; then
  die "lock hala SUDO_USER:-batu hardcode"
fi
ok "lock owner REMOTE_DIR'den"

grep -q 'ENABLE_TLS' "$PROJECT_DIR/scripts/mac/render-config.sh" \
  || die "render-config ENABLE_TLS okumuyor"
ok "ENABLE_TLS render'a bagli"

grep -q 'PI_TELEGRAM_BOT_TOKEN' "$compose" \
  || die "n8n PI_TELEGRAM env yok"
ok "n8n telegram env compose'da"

grep -q '/mnt/ssd/.disk-probe:/host-ssd:ro' "$compose" \
  || die "n8n hala genis /mnt/ssd mount kullaniyor"
ok "n8n disk-probe mount"

grep -q '127.0.0.1:3040' "$compose" \
  || die "homepage 127.0.0.1 bind degil"
ok "admin portlar localhost bind"

if grep -q 'HOMEPAGE_ALLOWED_HOSTS: "\*"' "$compose"; then
  die "HOMEPAGE_ALLOWED_HOSTS hala *"
fi
ok "homepage allowed hosts kisitli"

# Homepage docker.sock olmamali
if awk '/^  homepage:/,/^  [a-z]/ {print}' "$compose" | grep -q 'docker.sock'; then
  die "homepage hala docker.sock mount ediyor"
fi
ok "homepage docker.sock yok"

if awk '/^  dozzle:/,/^  [a-z]/ {print}' "$compose" | grep -q 'docker.sock'; then
  die "dozzle hala dogrudan docker.sock mount ediyor"
fi
grep -q 'docker-socket-proxy' "$compose" \
  || die "docker-socket-proxy servisi yok"
grep -q 'DOZZLE_REMOTE_HOST' "$compose" \
  || die "dozzle socket proxy kullanmiyor"
ok "dozzle socket proxy"

if grep -q '__TELEGRAM_BOT_TOKEN__' "$PROJECT_DIR/config/n8n/"*.workflow.json 2>/dev/null; then
  die "workflow JSON'da hala plaintext TELEGRAM placeholder var"
fi
ok "workflow token placeholder temiz"

if grep -q 'down --remove-orphans' "$compose_up"; then
  die "recover-compose hala nükleer down --remove-orphans kullaniyor"
fi
# Soft retry: docker network prune sonrasi ilk up force-recreate olmamali
soft="$(awk '/^docker network prune/,/^# Son care/' "$compose_up" | grep -v '^# Son care')"
echo "$soft" | grep -q 'force-recreate' \
  && die "ilk soft retry hala force-recreate"
grep -q 'force-recreate' "$compose_up" || die "son care force-recreate kayboldu"
ok "recover-compose soft sonra force"

grep -q 'TimeoutStartSec=300' "$PROJECT_DIR/host/systemd/pi-gateway-stack-watchdog.service" \
  || die "watchdog TimeoutStartSec 300 degil"
ok "watchdog timeout 300s"

grep -q '/usr/local/lib/pi-gateway' "$PROJECT_DIR/host/systemd/pi-gateway-recover-ro.service" \
  || die "recover-ro hala kullanici repo path"
ok "recover root-owned lib path"

grep -q '__CADDY_BASIC_AUTH__' "$PROJECT_DIR/config/caddy/Caddyfile.template" \
  || die "Caddy template basic_auth placeholder yok"
ok "Caddy basic_auth placeholder"

grep -q 'CHANGE_ME_' "$PROJECT_DIR/.env.example" \
  || die ".env.example CHANGE_ME placeholder yok"
if grep -qE 'DegistirBunu|DegistirRestic|DegistirForgejo' "$PROJECT_DIR/.env.example"; then
  die ".env.example hala sabit eski sifre iceriyor"
fi
ok ".env.example guvenli placeholders"

grep -q 'NODES_EXCLUDE.*executeCommand' "$compose" \
  || die "n8n executeCommand exclude yok"
ok "n8n executeCommand kapali"

grep -q 'N8N_WEBHOOK_SECRET' "$PROJECT_DIR/.env.example" \
  || die "N8N_WEBHOOK_SECRET .env.example yok"
ok "webhook secret tanimli"

grep -q 'install-privileged-scripts' "$PROJECT_DIR/scripts/pi/bootstrap.sh" \
  || die "bootstrap privileged install cagirmiyor"
ok "bootstrap privileged install"

grep -q 'root_rw_ok' "$stack_health" \
  || die "stack-health root_rw_ok yok"
grep -q 'stack_fully_healthy && root_rw_ok' "$stack_health" \
  || die "trigger_stack_recover root RO iken erken cikis yapiyor"
ok "recover root RO erken cikis yok"

grep -q 'container_health_ok' "$stack_health" \
  || die "stack_core_ok container health kontrolu yok"
ok "stack_core_ok health kontrolu"

grep -q 'PI_SSD_CONFIRM_FORMAT' "$PROJECT_DIR/scripts/pi/setup-ssd-data.sh" \
  || die "setup-ssd-data format onayi yok"
grep -q 'PI_SSD_DISK' "$PROJECT_DIR/scripts/pi/setup-ssd-data.sh" \
  || die "setup-ssd-data PI_SSD_DISK secimi yok"
ok "setup-ssd-data wipe korumasi"

grep -q 'Kurtarma tamamlandi ama root hala read-only' "$PROJECT_DIR/scripts/pi/check-sd-health.sh" \
  || die "check-sd-health yanlis recovered raporu duzeltilmemis"
ok "check-sd-health recovered mantigi"

grep -q '__CADDY_BASIC_AUTH__' "$PROJECT_DIR/config/caddy/Caddyfile.template" \
  && grep -A3 'http://gateway\.__LAN_DOMAIN__' "$PROJECT_DIR/config/caddy/Caddyfile.template" | grep -q '__CADDY_BASIC_AUTH__' \
  || die "gateway/panel Caddy auth yok"
grep -A3 'http://status\.__LAN_DOMAIN__' "$PROJECT_DIR/config/caddy/Caddyfile.template" | grep -q '__CADDY_BASIC_AUTH__' \
  || die "status Caddy auth yok"
ok "gateway/status Caddy auth"

grep -q 'SECRET_MARKER' "$PROJECT_DIR/scripts/pi/setup-n8n-workflows.sh" \
  || die "n8n workflow webhook guncelleme yok"
ok "n8n webhook guncelleme"

echo "[validate-stack] Tum kontroller gecti"
