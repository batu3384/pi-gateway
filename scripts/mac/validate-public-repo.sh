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

# Tracked dosyalarda gercek secret pattern (placeholder haric; pipefail SIGPIPE-safe capture)
_tok_hits="$(git grep -nE 'AA[A-Za-z0-9_-]{30,}' -- ':!*.example' ':!scripts/mac/validate-public-repo.sh' 2>/dev/null \
  | grep -v 'CHANGE_ME' | grep -v 'YOUR_' || true)"
if [[ -n "$_tok_hits" ]]; then
  printf '%s\n' "$_tok_hits" | head -5 >&2
  die "Telegram/API token benzeri pattern tracked dosyada"
fi

_mail_hits="$(git grep -nE '@(gmail|github)\.com' -- ':!*.example' 2>/dev/null \
  | grep -v 'example.com' | grep -v '@home.local' || true)"
if [[ -n "$_mail_hits" ]]; then
  printf '%s\n' "$_mail_hits" | head -5 >&2
  die "Gercek e-posta tracked dosyada (example.com / home.local haric)"
fi

# Kisisel LAN IP (.100–.119 / .112). Ornek DHCP: .50. SIGPIPE+pipefail flaky — capture.
_lan_hits="$(git grep -nE '192\.168\.1\.(10[0-9]|11[0-9]|112)' \
  -- ':!docs/ADGUARD-DHCP.md' ':!scripts/mac/validate-public-repo.sh' 2>/dev/null || true)"
if [[ -n "$_lan_hits" ]]; then
  printf '%s\n' "$_lan_hits" | head -5 >&2
  die "Kisisel LAN IP tracked dosyada"
fi
unset _lan_hits

_user_hits="$(git grep -nE 'batu@' -- ':!scripts/mac/validate-public-repo.sh' 2>/dev/null || true)"
if [[ -n "$_user_hits" ]]; then
  printf '%s\n' "$_user_hits" | head -5 >&2
  die "Kisisel kullanici adi tracked dosyada"
fi
unset _tok_hits _mail_hits _user_hits

[[ -f config/tailscale/acl.hujson ]] && git ls-files --error-unmatch config/tailscale/acl.hujson >/dev/null 2>&1 \
  && die "acl.hujson hala tracked — git rm --cached gerekli"

grep -q 'config/tailscale/acl.hujson' .gitignore || die "acl.hujson gitignore eksik"
grep -q 'host/dhcpcd/pi-gateway.conf' .gitignore || die "dhcpcd rendered conf gitignore eksik"
grep -q '\.env\.\*' .gitignore || die ".env.* gitignore eksik"
grep -q '\.pem' .gitignore || die "*.pem gitignore eksik"

python3 - <<'PY' || die "Tracked/untracked dosyada PII/secret/gercek MAC/IPv6 tespit edildi"
import pathlib
import re
import subprocess

files = subprocess.check_output(
    ["git", "ls-files", "--cached", "--others", "--exclude-standard"],
    text=True,
).splitlines()

skip = {"docs/ADGUARD-DHCP.md", "scripts/mac/validate-public-repo.sh"}
doc_v6 = ("2001:db8:", "2001:4860:", "2606:4700:", "2620:fe:", "2a00:1450:")
checks = [
    ("lan-ip", re.compile(r"\b192\.168\.1\.1\d{2}\b")),
    ("pi-oui-mac", re.compile(r"\b(?:d8[:-]3a[:-]dd|dc[:-]a6[:-]32|e4[:-]5f[:-]01|b8[:-]27[:-]eb|28[:-]cd[:-]c1|2c[:-]cf[:-]67)(?:[:-][0-9a-f]{2}){3}\b", re.I)),
    ("subscriber-ipv6", re.compile(r"\b2[0-9a-f]{3}:[0-9a-f:]{4,}\b", re.I)),
    ("private-key", re.compile(r"-----BEGIN [A-Z ]*PRIVATE KEY-----")),
    ("bcrypt-hash", re.compile(r"\$2[aby]\$\d{2}\$[./A-Za-z0-9]{50,}")),
]

hits = []
for rel in files:
    if rel in skip:
        continue
    p = pathlib.Path(rel)
    if not p.is_file():
        continue
    for lineno, line in enumerate(p.read_text(encoding="utf-8", errors="ignore").splitlines(), 1):
        for tag, rx in checks:
            for m in rx.finditer(line):
                val = m.group(0)
                if tag == "subscriber-ipv6" and any(val.lower().startswith(pref) for pref in doc_v6):
                    continue
                hits.append(f"{rel}:{lineno}: [{tag}] {val}")

if hits:
    raise SystemExit("\n".join(hits[:10]))
PY

ok "tracked+untracked secret/PII taramasi temiz"
echo "[validate-public] Public repo hazirlik kontrolleri gecti"
