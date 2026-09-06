#!/usr/bin/env bash
# DNS kapsam bypass — audit + cihaz/modem remediation adimlari (+ opsiyonel Telegram)
set -euo pipefail
REMOTE_DIR="${REMOTE_DIR:-/home/${USER}/pi-gateway}"
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=../lib/env-file.sh
source "$SCRIPT_DIR/../lib/env-file.sh"
read_remote_dotenv || { echo "[remediate-dns] HATA: .env" >&2; exit 1; }
# shellcheck source=../lib/notify.sh
source "$SCRIPT_DIR/../lib/notify.sh"
log() { echo "[remediate-dns] $*"; }
fail=0

audit="${SCRIPT_DIR}/audit-dns-coverage.sh"
diag="${SCRIPT_DIR}/diagnose-dns-bypass.sh"
state="${ADGUARD_DNS_COVERAGE_STATE_PATH:-/var/lib/pi-gateway/dns-coverage-state.json}"
audit_log="$(mktemp /tmp/pi-gateway-remediate-dns.XXXXXX)"
trap 'rm -f "$audit_log"' EXIT

echo "=== DNS kapsam remediation ==="
if [[ -x "$audit" ]]; then
  ADGUARD_COVERAGE_AUDIT_MODE=strict REMOTE_DIR="$REMOTE_DIR" bash "$audit" 2>&1 | tee "$audit_log" || fail=1
else
  log "HATA: audit-dns-coverage.sh yok"
  exit 1
fi

mapfile -t _rem < <(python3 - "$state" "$audit_log" <<'PY'
import json, re, sys
from pathlib import Path

state_path, audit_log = sys.argv[1], sys.argv[2]
st = {}
p = Path(state_path)
if p.is_file():
    try:
        st = json.loads(p.read_text(encoding="utf-8"))
    except (OSError, json.JSONDecodeError):
        pass
log_text = Path(audit_log).read_text(encoding="utf-8", errors="replace")
bypass = []
for line in log_text.splitlines():
    m = re.search(
        r"\[(POSSIBLE_BYPASS|BYPASS)\]\s+(\d+\.\d+\.\d+\.\d+)\s*(.*)$",
        line,
    )
    if m:
        tail = m.group(3).strip()
        bypass.append(f"{m.group(2)} {tail}" if tail else m.group(2))
m = re.search(r"MISSING_DEVICES:([0-9a-fA-F:.,]+)", log_text)
if m:
    have = {b.split()[0] for b in bypass}
    for ip in m.group(1).split(","):
        ip = ip.strip()
        if ip and ip not in have:
            bypass.append(ip)
pct = st.get("coverage_percent", -1)
status = st.get("status", "unknown")
print(f"status={status}")
print(f"pct={pct}")
print("bypass_count=" + str(len(bypass)))
for line in bypass[:12]:
    print("bypass:" + line)
PY
)

status="${_rem[0]#status=}"
pct="${_rem[1]#pct=}"
bypass_count="${_rem[2]#bypass_count=}"
mapfile -t bypass_lines < <(printf '%s\n' "${_rem[@]:3}" | sed -n 's/^bypass://p')

echo ""
echo "=== Ozet ==="
echo "Durum: ${status} | Kapsam: %${pct} | Bypass kaniti: ${bypass_count}"

if ((${#bypass_lines[@]})); then
  echo ""
  echo "=== Bypass cihazlar (elle) ==="
  for line in "${bypass_lines[@]}"; do
    echo "  * $line"
  done
  echo "  Android: Ayarlar → Ag → Ozel DNS → Kapali; Wi-Fi kapat/ac"
  echo "  iOS: Ozel Relay kapali; Wi-Fi yenile"
  echo "  Mac: make mac-dns"
fi

echo ""
echo "=== Modem (ZTE panel) ==="
echo "  DHCP DNS1=${PI_STATIC_IP:-Pi} DNS2=BOS"
echo "  WAN filtre: UDP/53 dis DNS drop; TCP/853 drop (${PI_STATIC_IP:-Pi} haric) — docs/DNS-BLOCKING.md"
echo "  Modem .1 reklam cozuyor — istemci yalniz Pi DNS kullanmali"

if [[ -x "$diag" ]]; then
  echo ""
  echo "=== Tam teşhis ==="
  REMOTE_DIR="$REMOTE_DIR" bash "$diag" 2>&1 | tail -5 || true
fi

if notify_enabled && ((${#bypass_lines[@]})); then
  detail="Bypass: ${bypass_count} cihaz — %${pct} kapsam"
  action="$(printf '%s\n' "${bypass_lines[@]}" | head -5 | tr '\n' ' · ')"
  action="${action} · Android Ozel DNS kapali · make remediate-dns"
  body="$(notify_html_alert "$detail" "$action")"
  notify_telegram "📡 DNS Kapsam" "$body" "dns-remediate" "HTML" || log "WARN: Telegram"
fi

if [[ "$status" == "fail" ]] || ((${#bypass_lines[@]} > 0)); then
  exit 1
fi
exit "$fail"
