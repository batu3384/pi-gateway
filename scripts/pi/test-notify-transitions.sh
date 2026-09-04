#!/usr/bin/env bash
# notify edge-trigger mantik self-check (Telegram yok)
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=../lib/env-file.sh
source "$SCRIPT_DIR/../lib/env-file.sh"
# shellcheck source=../lib/notify.sh
source "$SCRIPT_DIR/../lib/notify.sh"

export NOTIFY_STATE_DIR
NOTIFY_STATE_DIR="$(mktemp -d)"
export TELEGRAM_BOT_TOKEN='' TELEGRAM_CHAT_ID=''
export NOTIFY_REPEAT_SEC=3600

fail() { echo "[test-notify] FAIL: $*"; exit 1; }
ok() { echo "[test-notify] OK: $*"; }

hermes_home="$(mktemp -d)"
printf 'TELEGRAM_BOT_TOKEN=hermes-token\nTELEGRAM_CHAT_ID=hermes-chat\n' > "$hermes_home/.env"
export HERMES_HOME="$hermes_home"
if ! notify_enabled; then
  fail "Hermes Telegram credential fallback yok"
fi
[[ "$TELEGRAM_BOT_TOKEN" == "hermes-token" && "$TELEGRAM_CHAT_ID" == "hermes-chat" ]] \
  || fail "Hermes Telegram credential fallback hatali"
rm -rf "$hermes_home"
ok "Hermes credential fallback"

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

NOTIFY_REPEAT_SEC=3600
export TELEGRAM_BOT_TOKEN=test-token TELEGRAM_CHAT_ID=test-chat
notify_send_message() { return 1; }
notify_telegram "Başarısız gönderim" "" "send-fail"
[[ ! -f "${NOTIFY_STATE_DIR}/send-fail" ]] || fail "başarısız gönderim cooldown tüketti"
notify_send_message() { return 0; }
notify_telegram "Başarılı gönderim" "" "send-fail"
[[ -f "${NOTIFY_STATE_DIR}/send-fail" ]] || fail "başarılı gönderim cooldown yazmadı"
unset -f notify_send_message
ok "send-failure cooldown"

escaped="$(notify_html_alert 'a < b & c')"
[[ "$escaped" == *'a &lt; b &amp; c'* ]] || fail "HTML detail escape yok"
[[ "$(notify_html_alert_raw '<b>güvenli</b>')" == '<b>güvenli</b>' ]] \
  || fail "HTML raw fragment bozuldu"
captured=""
notify_send_message() { captured="$1"; return 0; }
notify_send_with_transition "title-escape" "fail" "A & B" "" "HTML"
[[ "$captured" == '<b>A &amp; B</b>' ]] || fail "HTML title escape yok"
unset -f notify_send_message
source "$SCRIPT_DIR/../lib/notify.sh"
curl() { printf '{"ok":false,"description":"test"}'; }
if notify_send_message "HTTP 200 false"; then
  fail "Telegram ok=false basarili sayildi"
fi
curl() { printf '{"ok":true,"result":{"message_id":1}}'; }
notify_send_message "HTTP 200 true" || fail "Telegram ok=true basarisiz sayildi"
unset -f curl
ok "HTML detail contract"

NOTIFY_REPEAT_SEC=0
notify_transition_peek "t" "fail" || fail "repeat fail peek"
ok "repeat fail"

# Default path kalici olmali (/run reboot'ta silinir)
grep -q '/var/lib/pi-gateway/notify' "$SCRIPT_DIR/../lib/notify.sh" \
  || fail "NOTIFY_STATE_DIR kalici path degil"
grep -q 'notify_touch_alive' "$SCRIPT_DIR/../lib/notify.sh" || fail "notify_touch_alive yok"
grep -q 'notify_boot_up' "$SCRIPT_DIR/../lib/notify.sh" || fail "notify_boot_up yok"
[[ -f "$SCRIPT_DIR/boot-notify.sh" ]] || fail "boot-notify.sh yok"
grep -q 'notify_hermes_inbox_up' "$SCRIPT_DIR/../lib/notify.sh" || fail "notify_hermes_inbox_up yok"
[[ -f "$SCRIPT_DIR/hermes-inbox-up-notify.sh" ]] || fail "hermes-inbox-up-notify.sh yok"
grep -q 'hermes-inbox-up-notify' "$SCRIPT_DIR/patch-hermes-telegram-pi.sh" \
  || fail "patch ExecStartPost hermes-up yok"
grep -q '_notify_stack_ok\|notify_stack_recovered' "$SCRIPT_DIR/recover-readonly-root.sh" \
  || fail "recover-readonly stack notify yok"
grep -q 'Asistan Sohbeti Aktif' "$SCRIPT_DIR/../lib/notify.sh" \
  || fail "asistan basligi yok"
! grep -qiE 'Inbox geri|Telegram inbox|getUpdates|stack ayağa|degraded mod|P2 —|saatte en fazla|Yedek SLA|· Yavaş|· Opsiyonel|· Stack' \
  "$SCRIPT_DIR/../lib/notify.sh" \
  || fail "kullaniciya jargon kalmis"
grep -q 'notify_ssd_restored' "$SCRIPT_DIR/../lib/notify.sh" \
  || fail "notify_ssd_restored yok"
grep -q 'notify_ssd_degraded' "$SCRIPT_DIR/../lib/notify.sh" \
  || fail "notify_ssd_degraded yok"
grep -q 'notify_ssd_fail_closed' "$SCRIPT_DIR/../lib/notify.sh" \
  || fail "notify_ssd_fail_closed yok"
grep -q 'notify_rate_commit' "$SCRIPT_DIR/../lib/notify.sh" \
  || fail "notify_rate_commit yok"
grep -q 'notify_slo_ops' "$SCRIPT_DIR/../lib/notify.sh" \
  || fail "notify_slo_ops yok"
ok "boot+persist+stack recover wiring"

rm -rf "$NOTIFY_STATE_DIR"
ok "tum transition testleri gecti"
