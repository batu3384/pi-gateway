#!/usr/bin/env bash
# Haftalik DNS kapsam ozeti — Telegram
set -euo pipefail
REMOTE_DIR="${REMOTE_DIR:-/home/${USER}/pi-gateway}"
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=../lib/env-file.sh
source "$SCRIPT_DIR/../lib/env-file.sh"
read_remote_dotenv || { echo "[dns-weekly] HATA: .env" >&2; exit 1; }
load_telegram_from_hermes || true
# shellcheck source=../lib/notify.sh
source "$SCRIPT_DIR/../lib/notify.sh"
log() { echo "[dns-weekly] $*"; }

notify_enabled || { log "TELEGRAM eksik — atlandi"; exit 0; }

state="${ADGUARD_DNS_COVERAGE_STATE_PATH:-/var/lib/pi-gateway/dns-coverage-state.json}"
audit="${REMOTE_DIR}/scripts/pi/audit-dns-coverage.sh"
[[ -x "$audit" ]] && ADGUARD_COVERAGE_AUDIT_MODE=warn REMOTE_DIR="$REMOTE_DIR" bash "$audit" >/dev/null 2>&1 || true

body="$(python3 - "$state" <<'PY'
import html, json, sys
from pathlib import Path
st = {}
p = Path(sys.argv[1])
if p.is_file():
    try:
        st = json.loads(p.read_text(encoding="utf-8"))
    except (OSError, json.JSONDecodeError):
        pass
pct = st.get("coverage_percent", -1)
active = st.get("active_devices", -1)
using = st.get("using_pi_dns", -1)
status = st.get("status", "unknown")
lines = [
    f"Doğrulanan cihaz: <b>{using}/{active}</b> (%{pct})" if pct >= 0 else "Kanıt yok",
    f"Durum: <code>{html.escape(str(status))}</code>",
]
if st.get("protocol_unknown"):
    lines.append("Protokol API’de yok — DoH/DoT ayrımı yapılamıyor.")
detail = "\n".join(lines)
action = "• Bypass şüphesi: /dns veya make audit-dns\n• TV/IoT: elle Pi DNS\n• Modem DNS2=.1 firmware tavanı"
print(
    f"{detail}\n\n{action}"
)
PY
)"

notify_telegram "📋 Haftalık DNS Kapsam" "$(notify_html_alert "$body" "")" "dns-weekly-report" "HTML"
log "OK"
