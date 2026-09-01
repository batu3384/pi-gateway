#!/usr/bin/env bash
set -euo pipefail
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
die() { echo "[test-telegram-ops] HATA: $*" >&2; exit 1; }
ok() { echo "[test-telegram-ops] OK: $*"; }

ops="$ROOT/scripts/pi/telegram-ops.sh"
menu="$ROOT/scripts/pi/telegram-menu.sh"
panels="$ROOT/scripts/lib/telegram-panels.py"
card="$ROOT/scripts/lib/telegram-status-card.py"

[[ -x "$ops" ]] || die "telegram-ops.sh executable degil"
grep -q 'notify_enabled' "$ops" || die "telegram-ops notify yok"
for skill in menu dns ssd backup recover; do
  [[ -f "$ROOT/config/hermes/skills/$skill/SKILL.md" ]] || die "skill $skill yok"
done
[[ ! -f "$ROOT/config/hermes/skills/paneller/SKILL.md" ]] || die "paneller skill kaldirilmali"
grep -q 'remove_keyboard' "$menu" || die "sticky keyboard kaldirma yok"
[[ "$(python3 "$panels" use_reply_keyboard 2>/dev/null)" == "0" ]] || die "use_reply_keyboard 0 olmali"
! grep -q '_send_reply_kb' "$card" || die "reply kb kodu kaldi"
grep -q '/dns /ssd /backup' "$card" || die "status card komut footer yok"
python3 "$ROOT/scripts/lib/ssd-usb-metrics.py" --self-check || die "ssd-usb-metrics self-check"
ok "telegram ops + panel cleanup"
