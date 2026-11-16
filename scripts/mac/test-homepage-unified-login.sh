#!/usr/bin/env bash
# Glance gateway widget + unified login contract
set -euo pipefail
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
die() { echo "[test-homepage-unified] HATA: $*" >&2; exit 1; }

grep -q 'gateway-state' "$ROOT/compose/docker-compose.yml" || die "gateway-state servisi yok"
grep -q 'custom-api' "$ROOT/config/glance/glance.yml.template" || die "glance custom-api widget yok"
grep -q 'http://gateway-state/state.json' "$ROOT/config/glance/glance.yml.template" \
  || die "gateway-state URL yok"
[[ -f "$ROOT/scripts/lib/unified-login.sh" ]] || die "unified-login.sh yok"
grep -q 'apply_unified_login' "$ROOT/scripts/lib/common.sh" || die "common.sh unified-login wire yok"
grep -q 'UNIFIED_LOGIN' "$ROOT/scripts/pi/post-deploy.sh" || die "post-deploy unified login yok"
echo "[test-glance-unified] OK"
