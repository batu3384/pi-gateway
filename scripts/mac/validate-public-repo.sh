#!/usr/bin/env bash
# Public repo oncesi: tracked dosyalarda secret/PII taramasi
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROJECT_DIR="$(cd "$SCRIPT_DIR/../.." && pwd)"

die() { echo "[validate-public] HATA: $*" >&2; exit 1; }
ok() { echo "[validate-public] OK: $*" ; }

cd "$PROJECT_DIR"

[[ -f LICENSE ]] || die "LICENSE eksik (public repo icin MIT vb. gerekli)"
[[ -f .github/SECURITY.md ]] || die ".github/SECURITY.md eksik"

# Makefile tum .env'i export etmemeli (secret sızıntısı)
if grep -E '^-include \.env|^include \.env' Makefile >/dev/null 2>&1; then
  die "Makefile .env include ediyor — secret leak riski"
fi
if grep -E '^export$' Makefile >/dev/null 2>&1; then
  die "Makefile global export — secret leak riski"
fi

# Tracked dosyalarda gercek secret pattern (placeholder haric)
if git grep -E 'AA[A-Za-z0-9_-]{30,}' -- ':!*.example' ':!scripts/mac/validate-public-repo.sh' 2>/dev/null \
  | grep -v 'CHANGE_ME' | grep -v 'YOUR_' | head -1; then
  die "Telegram/API token benzeri pattern tracked dosyada"
fi

if git grep -E '@(gmail|github)\.com' -- ':!*.example' 2>/dev/null \
  | grep -v 'example.com' | grep -v '@home.local' | head -1; then
  die "Gercek e-posta tracked dosyada (example.com / home.local haric)"
fi

# Kisisel LAN IP (ornek subnet dokumanlari haric)
if git grep -E '192\.168\.1\.(10[0-9]|11[0-9]|112)' \
  -- ':!docs/ADGUARD-DHCP.md' ':!scripts/mac/validate-public-repo.sh' 2>/dev/null | head -1; then
  die "Kisisel LAN IP tracked dosyada"
fi

if git grep -E 'batu@' -- ':!scripts/mac/validate-public-repo.sh' 2>/dev/null | head -1; then
  die "Kisisel kullanici adi tracked dosyada"
fi

[[ -f config/tailscale/acl.hujson ]] && git ls-files --error-unmatch config/tailscale/acl.hujson >/dev/null 2>&1 \
  && die "acl.hujson hala tracked — git rm --cached gerekli"

grep -q 'config/tailscale/acl.hujson' .gitignore || die "acl.hujson gitignore eksik"
grep -q 'host/dhcpcd/pi-gateway.conf' .gitignore || die "dhcpcd rendered conf gitignore eksik"
grep -q '\.env\.\*' .gitignore || die ".env.* gitignore eksik"
grep -q '\.pem' .gitignore || die "*.pem gitignore eksik"

ok "tracked secret/PII taramasi temiz"
echo "[validate-public] Public repo hazirlik kontrolleri gecti"
