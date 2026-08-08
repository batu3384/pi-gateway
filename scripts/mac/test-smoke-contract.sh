#!/usr/bin/env bash
# Smoke kontrat testleri (Mac/CI — Pi runtime gerektirmez)
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROJECT_DIR="$(cd "$SCRIPT_DIR/../.." && pwd)"
SMOKE="$PROJECT_DIR/scripts/pi/smoke-test.sh"

die() { echo "[test-smoke-contract] HATA: $*" >&2; exit 1; }
ok() { echo "[test-smoke-contract] OK: $*"; }

[[ -f "$SMOKE" ]] || die "smoke-test.sh yok"

for needle in \
  'ufw-ssh-lan' \
  'ufw-active' \
  'ufw-dns-lan' \
  'adguard-dhcp-config' \
  'privileged-lib-sync' \
  'run_check'; do
  grep -q "$needle" "$SMOKE" || die "smoke eksik: $needle"
done
ok "zorunlu smoke check isimleri"

grep -q 'adguard-dhcp-config' "$SMOKE" \
  || die "adguard-dhcp smoke yok"
grep -q 'adguard-dhcp' "$SMOKE" \
  || die "adguard-dhcp kosulu yok"
ok "adguard-dhcp kosullu"

grep -q 'DEGRADED' "$SMOKE" || die "degraded subset yok"
ok "degraded mode"

grep -q 'ENABLE_REDIS:-false' "$SMOKE" \
  || die "smoke REDIS default false degil"
ok "redis default kapali"

echo "[test-smoke-contract] Tum kontroller gecti"
