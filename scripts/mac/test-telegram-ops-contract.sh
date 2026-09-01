#!/usr/bin/env bash
set -euo pipefail
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
die() { echo "[test-telegram-ops] HATA: $*" >&2; exit 1; }
ok() { echo "[test-telegram-ops] OK: $*"; }

ops="$ROOT/scripts/pi/telegram-ops.sh"
menu="$ROOT/scripts/pi/telegram-menu.sh"
panels="$ROOT/scripts/lib/telegram-panels.py"
card="$ROOT/scripts/lib/telegram-status-card.py"
metrics="$ROOT/scripts/lib/ssd-usb-metrics.py"

[[ -x "$ops" ]] || die "telegram-ops.sh executable degil"
grep -q 'notify_enabled' "$ops" || die "telegram-ops notify yok"
grep -q 'recover onay' "$ops" || die "recover onay akisi yok"
grep -q 'telegram-recover.lock' "$ops" || die "recover lock yok"
grep -q 'env-file' "$ops" || die "restic env-file yok"
for skill in menu dns ssd backup recover recover-ask; do
  [[ -f "$ROOT/config/hermes/skills/$skill/SKILL.md" ]] || die "skill $skill yok"
done
[[ ! -f "$ROOT/config/hermes/skills/paneller/SKILL.md" ]] || die "paneller skill kaldirilmali"
grep -q 'remove_keyboard' "$menu" || die "sticky keyboard kaldirma yok"
[[ "$(python3 "$panels" use_reply_keyboard 2>/dev/null)" == "0" ]] || die "use_reply_keyboard 0 olmali"
! grep -q '_send_reply_kb' "$card" || die "reply kb kodu kaldi"
grep -q '/dns /ssd /backup' "$card" || die "status card komut footer yok"
grep -q 'journalctl' "$metrics" || die "ssd-usb-metrics journalctl yok"
grep -q 'last_alert_sig' "$metrics" || die "ssd-usb-metrics alert dedup yok"
python3 "$metrics" --self-check || die "ssd-usb-metrics self-check"
grep -q 'notify_restic_offsite_missing' "$ROOT/scripts/lib/notify.sh" || die "offsite missing notify yok"
grep -q 'NOTIFY_USB_FLAP_REPEAT_SEC' "$ROOT/scripts/lib/notify.sh" || die "usb flap repeat yok"
! grep -q 'notify_html_alert.*<b>' "$ROOT/scripts/pi/dns-coverage-weekly.sh" \
  || die "dns-weekly double-html risk"
ok "telegram ops + review fixes"
