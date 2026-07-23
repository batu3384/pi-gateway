#!/usr/bin/env bash
# Hybrid mimari kontrat testleri (Mac + repo)
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROJECT_DIR="$(cd "$SCRIPT_DIR/../.." && pwd)"

die() { echo "[validate-hybrid] HATA: $*" >&2; exit 1; }
ok() { echo "[validate-hybrid] OK: $*"; }

RESTORE="$PROJECT_DIR/scripts/mac/restore-hybrid-boot.sh"
VERIFY="$PROJECT_DIR/scripts/mac/verify-hybrid-boot.sh"
CLOUD_INIT="$PROJECT_DIR/scripts/lib/hybrid-cloud-init.sh"
PARTUUID_LIB="$PROJECT_DIR/scripts/lib/mbr-partuuid.sh"
POST_DEPLOY="$PROJECT_DIR/scripts/pi/post-deploy.sh"
BOOTSTRAP="$PROJECT_DIR/scripts/pi/bootstrap.sh"
SYMLINK="$PROJECT_DIR/scripts/lib/ensure-data-symlink.sh"
HOTPLUG="$PROJECT_DIR/scripts/pi/ssd-hotplug-handler.sh"
SETUP_HYBRID="$PROJECT_DIR/scripts/mac/setup-hybrid.sh"
REGRESSION="$SCRIPT_DIR/test-hybrid-contract.sh"
SSD_SERVICE="$PROJECT_DIR/host/systemd/pi-ssd-data.service"

[[ -f "$RESTORE" ]] || die "restore-hybrid-boot.sh yok"
[[ -f "$VERIFY" ]] || die "verify-hybrid-boot.sh yok"
[[ -f "$CLOUD_INIT" ]] || die "hybrid-cloud-init.sh yok"
[[ -f "$REGRESSION" ]] || die "test-hybrid-contract.sh yok"

grep -q 'detect_sd_root_partuuid' "$RESTORE" || die "restore dinamik PARTUUID yok"
grep -q 'hybrid_write_ssd_user_data' "$RESTORE" || die "restore SSD user-data yok"
grep -q 'root=PARTUUID=\${SD_ROOT_PARTUUID}' "$RESTORE" || die "restore zorunlu SD root yok"
grep -q 'eraseDisk free none' "$RESTORE" || die "restore diskutil SSD wipe yok"
ok "restore-hybrid-boot.sh kontrat"

grep -q 'detect_sd_root_partuuid' "$VERIFY" || die "verify dinamik PARTUUID yok"
grep -q 'pi-ssd-data.service' "$VERIFY" || die "verify user-data SSD unit kontrolu yok"
ok "verify-hybrid-boot.sh kontrat"

grep -q 'hybrid_write_fresh_install_cloud_init' "$CLOUD_INIT" || die "fresh cloud-init yok"
grep -q 'hybrid_inject_ssd_into_user_data' "$CLOUD_INIT" || die "user-data inject yok"
grep -q 'PI_SSD_CONFIRM_FORMAT=yes' "$CLOUD_INIT" || die "hybrid-cloud-init format onayi yok"
ok "hybrid-cloud-init.sh kontrat"

grep -q 'detect_sd_root_partuuid' "$PARTUUID_LIB" || die "detect_sd_root_partuuid yok"
grep -q 'mbr_root_partuuid_from_disk' "$PARTUUID_LIB" || die "mbr_root_partuuid_from_disk yok"
ok "mbr-partuuid.sh kontrat"

grep -q 'hybrid_write_fresh_install_cloud_init' "$SETUP_HYBRID" \
  || die "setup-hybrid paylasilan cloud-init kullanmiyor"
ok "setup-hybrid tek kaynak"

grep -q 'setup-ssd-data.sh' "$POST_DEPLOY" || die "post-deploy setup-ssd-data cagrisi yok"
grep -q 'PI_SSD_CONFIRM_FORMAT=yes' "$POST_DEPLOY" || die "post-deploy format onayi yok"
ok "post-deploy hybrid SSD zinciri"

grep -q 'setup-ssd-data.sh' "$BOOTSTRAP" || die "bootstrap setup-ssd-data yok"
grep -q 'PI_SSD_CONFIRM_FORMAT=yes' "$BOOTSTRAP" || die "bootstrap format onayi yok"
grep -q 'HATA: SSD veri diski hazirlanamadi' "$BOOTSTRAP" || die "bootstrap SSD fail-hard yok"
grep -q 'HATA: data symlink onarilamadi' "$BOOTSTRAP" || die "bootstrap symlink fail-hard yok"
ok "bootstrap hybrid SSD zinciri"

grep -q 'STORAGE_FALLBACK_SD' "$SYMLINK" || die "ensure-data-symlink STORAGE_FALLBACK_SD yok"
grep -q 'STORAGE_FALLBACK_SD=false' "$SYMLINK" || die "ensure-data-symlink fail-closed yok"
ok "ensure-data-symlink fail-closed"

RECOVER="$PROJECT_DIR/scripts/pi/recover-readonly-root.sh"
COMPOSE_UP="$PROJECT_DIR/scripts/pi/recover-compose-up.sh"
STACK_HEALTH="$PROJECT_DIR/scripts/lib/stack-health.sh"

grep -q 'dns_degraded_on_ssd_loss' "$STACK_HEALTH" || die "stack-health dns_degraded_on_ssd_loss yok"
grep -q 'DNS_DEGRADED_ON_SSD_LOSS' "$HOTPLUG" || die "hotplug DNS_DEGRADED_ON_SSD_LOSS yok"
grep -q 'dns_degraded_on_ssd_loss' "$HOTPLUG" || die "hotplug dns_degraded_on_ssd_loss cagrisi yok"
grep -q 'fail-closed' "$HOTPLUG" || die "hotplug fail-closed guard yok"
grep -q 'COMPOSE_RECOVER_MODE=core-dns' "$HOTPLUG" || die "hotplug core-dns compose yok"
ok "ssd-hotplug DNS degraded"

grep -q 'dns_degraded_on_ssd_loss' "$RECOVER" || die "recover dns_degraded_on_ssd_loss yok"
grep -q 'enter_degraded_mode' "$RECOVER" || die "recover enter_degraded_mode yok"
grep -q 'core-dns' "$RECOVER" || die "recover core-dns yok"
ok "recover-readonly-root DNS degraded"

grep -q 'COMPOSE_RECOVER_MODE=core-dns' "$COMPOSE_UP" || die "recover-compose core-dns yok"
grep -q 'SSD yok' "$COMPOSE_UP" || die "recover-compose SSD guard yok"
ok "recover-compose-up storm guard"

JOURNAL_CONF="$PROJECT_DIR/host/systemd/journald.conf.d/00-pi-gateway-persistent.conf"
[[ -f "$JOURNAL_CONF" ]] || die "journald persistent conf yok"
grep -q 'Storage=persistent' "$JOURNAL_CONF" || die "journald Storage=persistent yok"
grep -q 'journald.conf.d' "$BOOTSTRAP" || die "bootstrap journald install yok"
ok "persistent journal"

grep -q 'PI_SSD_CONFIRM_FORMAT=yes' "$SSD_SERVICE" || die "pi-ssd-data.service format onayi yok"
grep -q 'pi-setup-ssd-data.sh' "$PROJECT_DIR/scripts/pi/install-privileged-scripts.sh" \
  || die "install-privileged pi-setup-ssd-data yok"
ok "systemd + privileged install"

grep -q 'user-data' "$PROJECT_DIR/scripts/lib/bootfs-sync.sh" \
  || die "bootfs-sync cloud-init exclude yok"
ok "bootfs-sync cloud-init koruma"

echo "[validate-hybrid] Statik kontrat testleri gecti"
bash "$REGRESSION"
