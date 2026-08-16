#!/usr/bin/env bash
# Telegram bildirim testi (düzgün Türkçe UTF-8)
set -euo pipefail
REMOTE_DIR="${REMOTE_DIR:-/home/${USER}/pi-gateway}"
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
_PG_ENV_LIB="${SCRIPT_DIR:-$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)}/../lib/env-file.sh"
PG_SCRIPT_NAME="$(basename "$0")"
# shellcheck source=../lib/env-file.sh
source "${_PG_ENV_LIB:?}"
read_remote_dotenv || { echo "[${PG_SCRIPT_NAME:-script}] HATA: .env dotenv parser hatasi" >&2; exit 1; }
source "$SCRIPT_DIR/../lib/notify.sh"
notify_enabled || { echo "TELEGRAM_BOT_TOKEN ve TELEGRAM_CHAT_ID .env içinde olmalı"; exit 1; }
gateway="$(panel_url gateway)"
body="$(printf 'Bildirimler aktif.\n\n<b>Ana panel:</b> %s\n<b>Menü:</b> Pi bot <code>/menu</code> veya Mac <code>make telegram-menu</code>\n\n<i>Uyarılar bu bottan; panel linkleri ayrı servis (telegram-bot).</i>' "$gateway")"
text="$(printf '✅ Pi Gateway\n\n%s' "$body")"
NOTIFY_COOLDOWN_SEC=0 notify_rate_ok "test-once" || true
notify_send_message "$text" "HTML" || { echo "Telegram gönderilemedi"; exit 1; }
echo "Test mesajı gönderildi."
