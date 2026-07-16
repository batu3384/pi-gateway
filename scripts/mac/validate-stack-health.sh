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

if grep -q 'acquire_recover_lock ||' "$recover" && grep -q 'exit 0' "$recover"; then
  grep -A2 'acquire_recover_lock' "$recover" | grep -q 'exit 0' \
    && die "recover kilidi alinamazken exit 0 kullaniyor"
fi
ok "recover lock fail semantigi"

grep -q 'ENABLE_TLS' "$PROJECT_DIR/scripts/mac/render-config.sh" \
  || die "render-config ENABLE_TLS okumuyor"
ok "ENABLE_TLS render'a bagli"

grep -q 'PI_TELEGRAM_BOT_TOKEN' "$PROJECT_DIR/compose/docker-compose.yml" \
  || die "n8n PI_TELEGRAM env yok"
ok "n8n telegram env compose'da"

if grep -q '__TELEGRAM_BOT_TOKEN__' "$PROJECT_DIR/config/n8n/"*.workflow.json 2>/dev/null; then
  die "workflow JSON'da hala plaintext TELEGRAM placeholder var"
fi
ok "workflow token placeholder temiz"

echo "[validate-stack] Tum kontroller gecti"
