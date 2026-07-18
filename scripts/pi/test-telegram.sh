#!/usr/bin/env bash
# Telegram bildirim testi (düzgün Türkçe UTF-8)
set -euo pipefail

REMOTE_DIR="${REMOTE_DIR:-/home/${USER}/pi-gateway}"
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=/dev/null
[[ -f "$REMOTE_DIR/.env" ]] && source "$REMOTE_DIR/.env"
# shellcheck source=../lib/notify.sh
source "$SCRIPT_DIR/../lib/notify.sh"

notify_enabled || { echo "TELEGRAM_BOT_TOKEN ve TELEGRAM_CHAT_ID .env içinde olmalı"; exit 1; }

gateway="$(panel_url gateway)"
body="$(printf 'Bildirimler aktif.\n\n<b>Ana panel:</b> %s\n<b>Menü:</b> Mac'\''te <code>make telegram-menu</code>\n\n<i>Bu bot yalnızca uyarı gönderir; mesajlarınıza cevap vermez.</i>' "$gateway")"
text="$(printf '✅ Pi Gateway\n\n%s' "$body")"

NOTIFY_COOLDOWN_SEC=0 notify_rate_ok "test-once" || true
notify_send_message "$text" "HTML" || { echo "Telegram gönderilemedi"; exit 1; }
echo "Test mesajı gönderildi."
