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

grep -q 'STACK_RECOVER_WAIT_SEC:-330' "$stack_health" \
  || die "STACK_RECOVER_WAIT_SEC default 330 degil"
grep -q 'TimeoutStartSec=360' "$PROJECT_DIR/host/systemd/pi-gateway-recover-ro.service" \
  || die "recover-ro TimeoutStartSec 360 degil"
ok "recover wait/timeout 330/360s hizali"

grep -q 'apply_adguard_rewrites_best_effort' "$recover" \
  || die "recover rewrite best-effort cagirmiyor"
grep -A3 'Stack saglikli ve root rw' "$recover" | grep -q 'apply_adguard_rewrites' \
  || die "early healthy exit rewrite uygulamıyor"
ok "recover rewrite early+success yollari"

grep -q 'pi_user_from_remote_dir' "$stack_health" \
  || die "lock owner pi_user_from_remote_dir kullanmiyor"
if grep -q 'SUDO_USER:-pi' "$stack_health"; then
  die "lock hala SUDO_USER:-pi hardcode"
fi
ok "lock owner REMOTE_DIR'den"

grep -q 'ENABLE_TLS' "$PROJECT_DIR/scripts/mac/render-config.sh" \
  || die "render-config ENABLE_TLS okumuyor"
ok "ENABLE_TLS render'a bagli"

grep -q 'PI_TELEGRAM_BOT_TOKEN' "$compose" \
  || die "n8n PI_TELEGRAM env yok"
ok "n8n telegram env compose'da"

grep -q '/data/.disk-probe:/host-ssd:ro' "$compose" \
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

grep -q 'TimeoutStartSec=360' "$PROJECT_DIR/host/systemd/pi-gateway-stack-watchdog.service" \
  || die "watchdog TimeoutStartSec 360 degil"
ok "watchdog timeout 360s"

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

grep -q 'RENDER_MARKER' "$PROJECT_DIR/scripts/pi/setup-n8n-workflows.sh" \
  || die "n8n workflow render marker yok"
grep -q '__PANEL_PROTOCOL__' "$PROJECT_DIR/config/n8n/uptime-kuma-alert.workflow.json" \
  || die "n8n uptime workflow PANEL_PROTOCOL yok"
grep -q 'ensure-n8n-encryption-key' "$PROJECT_DIR/scripts/pi/post-deploy.sh" \
  || die "post-deploy n8n encryption key yok"
grep -q 'update:workflow.*active=true' "$PROJECT_DIR/scripts/pi/setup-n8n-workflows.sh" \
  || die "n8n workflow aktivasyonu yok"
ok "n8n webhook guncelleme + aktivasyon"

grep -q '/run/pi-gateway/stack-recover.lock' "$stack_health" \
  || die "STACK_LOCK_FILE tmpfs degil"
ok "lock tmpfs path"

grep -q 'ensure_root_rw' "$recover" \
  || die "recover ensure_root_rw yok"
grep -q 'stack_fully_healthy && root_rw_ok' "$recover" \
  || die "recover early exit root_rw_ok yok"
ok "recover remount-before-lock + root_rw_ok early exit"

grep -q '! stack_fully_healthy || ! root_rw_ok' "$PROJECT_DIR/scripts/pi/health-check.sh" \
  || die "health-check root RO recover tetiklemesi yok"
grep -q 'recover-stack.sh' "$PROJECT_DIR/scripts/pi/health-check.sh" \
  || die "health-check recover-stack.sh cagirmiyor"
grep -q 'recover-stack.sh' "$watchdog" \
  || die "watchdog recover-stack.sh cagirmiyor"
[[ -f "$PROJECT_DIR/scripts/pi/recover-stack.sh" ]] \
  || die "recover-stack.sh yok"
ok "health-check recover tetiklemesi"

grep -q 'ENABLE_TLS=true' "$PROJECT_DIR/.env.example" \
  || die "ENABLE_TLS=true .env.example varsayilan degil"
grep -q 'WEAK_TLS_OK' "$PROJECT_DIR/scripts/mac/validate.sh" \
  || die "validate WEAK_TLS_OK fail-closed yok"
ok "TLS default + validate fail-closed"

if grep -E 'image:.*:latest' "$compose" >/dev/null 2>&1; then
  die "compose'da :latest kaldi — image pin zorunlu"
fi
ok "compose image pin (no :latest)"

grep -q 'NETALERTX_LISTEN_ADDR:-172.17.0.1' "$compose" \
  || die "NetAlertX listen default 172.17.0.1 degil"
ok "NetAlertX docker0 listen"

grep -q 'OFFSITE_BACKUP_MAX_AGE_DAYS' "$PROJECT_DIR/.env.example" \
  || die "OFFSITE_BACKUP_MAX_AGE_DAYS .env.example yok"
grep -q 'last-offsite-backup\|.last-success' "$PROJECT_DIR/scripts/mac/backup-pull.sh" \
  || die "backup-pull offsite stamp yazmiyor"
ok "offsite backup SLA stamp"

grep -q 'STORAGE_FALLBACK_SD' "$PROJECT_DIR/.env.example" \
  || die "STORAGE_FALLBACK_SD .env.example yok"
ok "STORAGE_FALLBACK_SD tanimli"

grep -q 'ssd_mount_healthy' "$PROJECT_DIR/scripts/lib/ssd-alive.sh" \
  || die "ssd-alive.sh yok/eksik"
grep -q 'PathExistsGone' "$PROJECT_DIR/host/systemd/pi-ssd-watch.path" \
  || die "PathExistsGone yok"
grep -q 'ssd-alive.sh' "$PROJECT_DIR/scripts/pi/install-privileged-scripts.sh" \
  || die "install-privileged ssd-alive kopyalamiyor"
ok "SSD auto-recovery (alive+path+priv)"

[[ -f "$PROJECT_DIR/scripts/pi/setup-docker-fallback.sh" ]] \
  || die "setup-docker-fallback.sh yok"
ok "docker SD fallback script"

grep -q '/usr/local/lib/pi-gateway/scripts/pi/health-check.sh' \
  "$PROJECT_DIR/host/systemd/pi-gateway-health.service" \
  || die "health-check privileged lib path degil"
ok "health-check privileged lib path"

[[ -f "$PROJECT_DIR/scripts/pi/reboot-smoke.sh" ]] \
  || die "reboot-smoke.sh yok"
ok "reboot-smoke script"

morning_wf=""
for wf in "$PROJECT_DIR"/config/n8n/*.workflow.json; do
  [[ -f "$wf" ]] || continue
  if grep -q 'executeCommand' "$wf" 2>/dev/null; then
    morning_wf="$wf"
    break
  fi
done
[[ -z "$morning_wf" ]] || die "workflow executeCommand kullaniyor: $morning_wf"
ok "n8n workflow executeCommand yok (aktif set)"

grep -q 'caddy-.*-auth-deny' "$PROJECT_DIR/scripts/pi/smoke-test.sh" \
  || die "smoke Caddy auth deny testi yok"
ok "smoke auth iki yonlu"

grep -q 'n8n-kuma-webhook' "$PROJECT_DIR/scripts/pi/smoke-test.sh" \
  || die "smoke n8n webhook e2e yok"
ok "smoke n8n webhook e2e"

grep -q 'insecure_ssl' "$PROJECT_DIR/scripts/pi/setup-forgejo-webhook.sh" \
  && die "forgejo webhook insecure_ssl hala var"
ok "forgejo webhook ssl guvenli"

grep -q '127.0.0.1:.*8384' "$compose" \
  || die "syncthing GUI localhost bind yok"
grep -q '22000:22000/tcp' "$compose" \
  || die "syncthing sync port publish yok"
grep -q '127.0.0.1:22000' "$compose" \
  && die "syncthing 22000 localhost bind — Mac sync kirilir"
ok "syncthing GUI localhost, sync LAN"

grep -q 'network_mode: host' "$compose" \
  && grep -q 'container_name: netalertx' "$compose" \
  || die "netalertx host network yok"
grep -q 'docker-netalertx' "$PROJECT_DIR/scripts/pi/setup-firewall.sh" \
  || die "netalertx docker ufw kurali yok"
grep -q 'setup-netalertx.sh' "$PROJECT_DIR/scripts/pi/post-deploy.sh" \
  || die "post-deploy netalertx yok"
grep -q 'netalert-device-alert' "$PROJECT_DIR/config/n8n/netalert-device-alert.workflow.json" \
  || die "n8n netalert workflow yok"
ok "netalertx host network + webhook"

grep -q 'STORAGE_TYPE=hybrid' "$PROJECT_DIR/.env.example" \
  || die ".env.example hybrid varsayilan degil"
ok "hybrid varsayilan"

[[ -f "$PROJECT_DIR/scripts/mac/restore-hybrid-boot.sh" ]] \
  || die "restore-hybrid-boot.sh yok"
[[ -f "$PROJECT_DIR/scripts/mac/verify-hybrid-boot.sh" ]] \
  || die "verify-hybrid-boot.sh yok"
ok "hybrid mac scriptleri"

grep -q 'root_on_ssd\|is_ssd_root_mode' "$stack_health" \
  || die "stack-health ssd-root helper yok"
ok "ssd-root helpers"

[[ -f "$PROJECT_DIR/scripts/mac/migrate-sd-boot-ssd-root.sh" ]] \
  || die "migrate-sd-boot-ssd-root.sh yok"
[[ -f "$PROJECT_DIR/scripts/mac/verify-ssd-root.sh" ]] \
  || die "verify-ssd-root.sh yok"
[[ -f "$PROJECT_DIR/docs/SSD-ROOT.md" ]] \
  || die "docs/SSD-ROOT.md yok"
ok "ssd-root migration artefaktlari"

grep -q 'root-on-ssd' "$PROJECT_DIR/scripts/pi/smoke-test.sh" \
  || die "smoke root-on-ssd yok"
ok "smoke ssd-root check"

# verify false-green onleme: SD/SSD disk eslesmesi zorunlu
grep -q 'SD root.*SSD root\|SD ve SSD ayni root' "$PROJECT_DIR/scripts/mac/verify-ssd-root.sh" \
  || die "verify-ssd-root SD==SSD root kontrati yok"
grep -q 'yanlis disk\|path uyusmuyor' "$PROJECT_DIR/scripts/mac/verify-ssd-root.sh" \
  || die "verify-ssd-root disk eslesme kontrolu yok"
grep -q 'SD_ROOT_BEFORE\|flash oncesi SD root' "$PROJECT_DIR/scripts/mac/migrate-sd-boot-ssd-root.sh" \
  || die "migrate eski SD root carpismasi kontrolu yok"
ok "migrate/verify PARTUUID guvenlik kontrati"

[[ -f "$PROJECT_DIR/scripts/pi/neutralize-legacy-sd-root.sh" ]] \
  || die "neutralize-legacy-sd-root.sh yok"
ok "legacy SD root neutralize script"

[[ -f "$PROJECT_DIR/scripts/mac/validate-ssd-root-contract.sh" ]] \
  || die "validate-ssd-root-contract.sh yok"
ok "ssd-root contract test script"

[[ -f "$PROJECT_DIR/scripts/pi/ssd-root-harden.sh" ]] \
  || die "ssd-root-harden.sh yok"
ok "ssd-root-harden script"

grep -q 'sd_data_native_ok' "$PROJECT_DIR/scripts/lib/stack-health.sh" \
  || die "sd_data_native_ok helper yok"
ok "sd native data fallback helper"

grep -q 'notify_transition_peek' "$PROJECT_DIR/scripts/lib/notify.sh" \
  || die "notify transition peek yok"
grep -q 'notify_send_with_transition' "$PROJECT_DIR/scripts/lib/notify.sh" \
  || die "notify send-with-transition yok"
grep -q 'health_is_dns_only_fail' "$PROJECT_DIR/scripts/pi/health-check.sh" \
  || die "health dns-only fail ayrimi yok"
[[ -f "$PROJECT_DIR/scripts/pi/test-notify-transitions.sh" ]] \
  || die "test-notify-transitions.sh yok"
grep -q 'config/tailscale/acl.hujson' "$PROJECT_DIR/.gitignore" \
  || die "acl.hujson gitignore yok"
grep -q 'TAILSCALE_ACL_OWNER' "$PROJECT_DIR/.env.example" \
  || die "TAILSCALE_ACL_OWNER .env.example yok"
"$PROJECT_DIR/scripts/pi/test-notify-transitions.sh"
ok "notify transition testleri"

# Install-path regressions (adversarial 2026-07-25)
if grep -q 'UPTIME_KUMA_ADMIN_PASSWORD.*ENABLE_N8N' "$PROJECT_DIR/scripts/pi/post-deploy.sh"; then
  die "UPTIME_KUMA_ADMIN_PASSWORD hala ENABLE_N8N ile gate'li"
fi
ok "Kuma password check N8N'den bagimsiz"

grep -q 'ENABLE_AUTOHEAL:-false' "$PROJECT_DIR/scripts/mac/deploy.sh" \
  || die "deploy.sh AUTOHEAL default false degil"
grep -q 'ENABLE_AUTOHEAL:-false' "$PROJECT_DIR/scripts/lib/compose-profiles.sh" \
  || die "compose-profiles AUTOHEAL default false degil"
ok "AUTOHEAL defaults hizali"

grep -q 'doctor.sh' "$PROJECT_DIR/scripts/mac/install.sh" \
  || die "install.sh doctor cagirmiyor"
grep -q 'PI_STATIC_IP' "$PROJECT_DIR/scripts/mac/install.sh" \
  || die "install.sh PI_STATIC_IP fallback yok"
ok "install doctor + PI_STATIC_IP fallback"

grep -q 'wait_ssh' "$PROJECT_DIR/scripts/mac/deploy.sh" \
  || die "deploy.sh wait_ssh yok (dhcpcd sonrasi)"
grep -q 'ssh-copy-id' "$PROJECT_DIR/scripts/mac/deploy.sh" \
  || die "deploy wait_ssh SSH key mesaji yok"
ok "deploy SSH retry after bootstrap"

grep -q 'fresh_no_ssd\|fresh_no_repo' "$PROJECT_DIR/scripts/mac/pre-deploy-check.sh" \
  || die "pre-deploy fresh/broken ayrimi yok"
grep -q 'broken and repair failed' "$PROJECT_DIR/scripts/mac/pre-deploy-check.sh" \
  || die "pre-deploy broken hard-fail yok"
ok "pre-deploy fresh soft-fail / broken hard-fail"

# Legacy scripts/deploy.sh must wrap mac/deploy (no divergent ssd-root default)
if grep -q 'STORAGE_TYPE:-ssd-root' "$PROJECT_DIR/scripts/deploy.sh" 2>/dev/null; then
  die "scripts/deploy.sh hala ssd-root default — mac/deploy wrapper olmali"
fi
grep -q 'mac/deploy.sh' "$PROJECT_DIR/scripts/deploy.sh" \
  || die "scripts/deploy.sh mac/deploy wrapper degil"
ok "scripts/deploy.sh wraps mac/deploy"

echo "[validate-stack] Tum kontroller gecti"
