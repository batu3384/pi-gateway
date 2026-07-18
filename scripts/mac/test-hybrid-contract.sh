#!/usr/bin/env bash
# Hybrid kontrat regresyon testleri (Mac/Linux, disk gerekmez)
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROJECT_DIR="$(cd "$SCRIPT_DIR/../.." && pwd)"

die() { echo "[test-hybrid] HATA: $*" >&2; exit 1; }
ok() { echo "[test-hybrid] OK: $*"; }

# shellcheck source=../lib/mbr-partuuid.sh
source "$PROJECT_DIR/scripts/lib/mbr-partuuid.sh"
# shellcheck source=../lib/hybrid-cloud-init.sh
source "$PROJECT_DIR/scripts/lib/hybrid-cloud-init.sh"

tmp="$(mktemp -d)"
trap 'rm -rf "$tmp"' EXIT

# PARTUUID cmdline parse
printf '%s\n' 'foo root=PARTUUID=a49fcf66-02 bar' >"$tmp/cmdline.txt"
[[ "$(partuuid_from_cmdline_file "$tmp/cmdline.txt")" == "a49fcf66-02" ]] \
  || die "cmdline PARTUUID parse"
ok "cmdline PARTUUID parse"

printf '%s\n' 'root=PARTUUID=deadbeef-02' >"$tmp/cmdline.txt"
sd_root_partuuid_from_bootfs "$tmp" >/dev/null || die "bootfs cmdline okuma"
ok "bootfs cmdline okuma"

# user-data inject: mevcut users blogu korunur
cat >"$tmp/user-data" <<'EOF'
#cloud-config
hostname: testpi
users:
  - name: batu
enable_ssh: true
EOF

setup="$PROJECT_DIR/scripts/pi/setup-ssd-data.sh"
[[ -f "$setup" ]] || die "setup-ssd-data yok"
hybrid_inject_ssd_into_user_data "$tmp/user-data" "$setup" batu /home/batu/pi-gateway /mnt/ssd
grep -q '^users:' "$tmp/user-data" || die "inject users silindi"
grep -q 'hostname: testpi' "$tmp/user-data" || die "inject hostname silindi"
grep -q 'pi-ssd-data.service' "$tmp/user-data" || die "inject service yok"
grep -q 'PI_SSD_CONFIRM_FORMAT=yes' "$tmp/user-data" || die "inject format onayi yok"
grep -q 'pi-setup-ssd-data.sh' "$tmp/user-data" || die "inject script yok"
ok "user-data inject koruma"

# Ikinci inject idempotent (runcmd tekrarlanmaz)
lines_before="$(wc -l <"$tmp/user-data" | tr -d ' ')"
hybrid_inject_ssd_into_user_data "$tmp/user-data" "$setup" batu /home/batu/pi-gateway /mnt/ssd
lines_after="$(wc -l <"$tmp/user-data" | tr -d ' ')"
[[ "$lines_before" -eq "$lines_after" ]] || die "inject idempotent degil: $lines_before -> $lines_after"
enable_count="$(grep -c 'enable, pi-ssd-data.service' "$tmp/user-data" || true)"
[[ "$enable_count" -eq 1 ]] || die "inject runcmd tekrari: $enable_count"
ok "user-data inject idempotent"

# fresh install cloud-init
hybrid_write_fresh_install_cloud_init "$tmp/ci" "$setup" batu batu 'testpass123' \
  Europe/Istanbul tr_TR.UTF-8 /mnt/ssd
grep -q 'pi-ssd-data.service' "$tmp/ci/user-data" || die "fresh user-data service yok"
grep -q 'users:' "$tmp/ci/user-data" || die "fresh user-data users yok"
grep -q 'PI_SSD_CONFIRM_FORMAT=yes' "$tmp/ci/user-data" || die "fresh format onayi yok"
ok "fresh install cloud-init"

echo "[test-hybrid] Tum regresyon testleri gecti"
