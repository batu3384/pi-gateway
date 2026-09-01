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

mapfile -t _dns_weekly < <(python3 - "$state" <<'PY'
import json, sys
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
if pct >= 0:
    detail = f"Doğrulanan cihaz: {using}/{active} (%{pct}) — durum {status}"
else:
    detail = "Kanıt yok"
if st.get("protocol_unknown"):
    detail += " — protokol API bilinmiyor"
action = "Bypass: /dns veya make audit-dns · TV/IoT: elle Pi DNS · Modem DNS2=.1 tavanı"
print(detail)
print(action)
PY
)
detail="${_dns_weekly[0]:-Kanıt yok}"
action="${_dns_weekly[1]:-}"

body="$(notify_html_alert "$detail" "$action")"
notify_telegram "📋 Haftalık DNS Kapsam" "$body" "dns-weekly-report" "HTML"
log "OK"
