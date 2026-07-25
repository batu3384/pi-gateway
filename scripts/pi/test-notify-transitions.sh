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

rm -rf "$NOTIFY_STATE_DIR"
ok "tum transition testleri gecti"
