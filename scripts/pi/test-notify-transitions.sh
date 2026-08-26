#!/usr/bin/env bash
# notify edge-trigger mantik self-check (Telegram yok)
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=../lib/notify.sh
source "$SCRIPT_DIR/../lib/notify.sh"

export NOTIFY_STATE_DIR
NOTIFY_STATE_DIR="$(mktemp -d)"
export TELEGRAM_BOT_TOKEN='' TELEGRAM_CHAT_ID=''
export NOTIFY_REPEAT_SEC=3600

fail() { echo "[test-notify] FAIL: $*"; exit 1; }
ok() { echo "[test-notify] OK: $*"; }

notify_transition_peek "t" "fail" || fail "ilk fail peek"
notify_transition_commit "t" "fail"
notify_transition_peek "t" "fail" && fail "ikinci fail peek susturulmali"
ok "fail susturma"

# Basarisiz gonderim: commit yoksa peek fail acik kalir (sonraki timer yeniden dener)
notify_transition_peek "retry" "fail" || fail "retry ilk peek"
notify_transition_peek "retry" "fail" || fail "retry peek commit oncesi hala acik"
notify_transition_commit "retry" "fail"
notify_transition_peek "retry" "fail" && fail "retry peek commit sonrasi susturulmali"
ok "fail commit sonrasi susturma"

notify_transition_peek "t" "ok" || fail "recover peek"
notify_transition_commit "t" "ok"
notify_transition_peek "t" "ok" && fail "ok->ok peek susturulmali"
ok "recover"

NOTIFY_REPEAT_SEC=0
notify_transition_peek "t" "fail" || fail "repeat fail peek"
ok "repeat fail"

# Default path kalici olmali (/run reboot'ta silinir)
grep -q '/var/lib/pi-gateway/notify' "$SCRIPT_DIR/../lib/notify.sh" \
  || fail "NOTIFY_STATE_DIR kalici path degil"
grep -q 'notify_touch_alive' "$SCRIPT_DIR/../lib/notify.sh" || fail "notify_touch_alive yok"
grep -q 'notify_boot_up' "$SCRIPT_DIR/../lib/notify.sh" || fail "notify_boot_up yok"
[[ -f "$SCRIPT_DIR/boot-notify.sh" ]] || fail "boot-notify.sh yok"
grep -q '_notify_stack_ok\|notify_stack_recovered' "$SCRIPT_DIR/recover-readonly-root.sh" \
  || fail "recover-readonly stack notify yok"
ok "boot+persist+stack recover wiring"

rm -rf "$NOTIFY_STATE_DIR"
ok "tum transition testleri gecti"
