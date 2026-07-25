#!/usr/bin/env bash
# Public repo oncesi: tracked dosyalarda secret/PII taramasi
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROJECT_DIR="$(cd "$SCRIPT_DIR/../.." && pwd)"

die() { echo "[validate-public] HATA: $*" >&2; exit 1; }
ok() { echo "[validate-public] OK: $*" ; }

cd "$PROJECT_DIR"

# Tracked dosyalarda gercek secret pattern (placeholder haric)
if git grep -E 'AA[A-Za-z0-9_-]{30,}' -- ':!*.example' ':!docs/' ':!scripts/mac/validate-public-repo.sh' 2>/dev/null \
  | grep -v 'CHANGE_ME' | grep -v 'YOUR_' | head -1; then
  die "Telegram/API token benzeri pattern tracked dosyada"
fi

if git grep -E '@(gmail|github)\.com' -- ':!*.example' ':!docs/' 2>/dev/null | grep -v 'example.com' | head -1; then
  die "Gercek e-posta tracked dosyada (example.com haric)"
fi

[[ -f config/tailscale/acl.hujson ]] && git ls-files --error-unmatch config/tailscale/acl.hujson >/dev/null 2>&1 \
  && die "acl.hujson hala tracked — git rm --cached gerekli"

grep -q 'config/tailscale/acl.hujson' .gitignore || die "acl.hujson gitignore eksik"
grep -q 'host/dhcpcd/pi-gateway.conf' .gitignore || die "dhcpcd rendered conf gitignore eksik"
grep -q '\.env\.\*' .gitignore || die ".env.* gitignore eksik"

ok "tracked secret/PII taramasi temiz"
echo "[validate-public] Public repo hazirlik kontrolleri gecti"
