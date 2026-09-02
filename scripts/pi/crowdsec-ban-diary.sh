#!/usr/bin/env bash
# CrowdSec gece defteri — 24s ban ozeti + arsiv (LLM yok, kural tabanli).
set -euo pipefail
REMOTE_DIR="${REMOTE_DIR:-/home/${USER}/pi-gateway}"
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=../lib/env-file.sh
source "$SCRIPT_DIR/../lib/env-file.sh"
read_remote_dotenv || { echo "[crowdsec-diary] HATA: .env" >&2; exit 1; }
load_telegram_from_hermes || true
# shellcheck source=../lib/notify.sh
source "$SCRIPT_DIR/../lib/notify.sh"
ARCHIVE="$SCRIPT_DIR/../lib/archive-bulletin.sh"

log() { echo "[crowdsec-diary] $*"; }

if [[ "${1:-}" == "--self-check" ]]; then
  grep -q 'cscli decisions list' "$0" || exit 1
  log "self-check OK"
  exit 0
fi

docker ps --format '{{.Names}}' | grep -qx crowdsec || exit 0

body="$(docker exec crowdsec cscli decisions list -o json 2>/dev/null | python3 - <<'PY'
import json
import sys
from collections import Counter
from datetime import datetime, timedelta, timezone

raw = sys.stdin.read().strip()
if not raw:
    print("")
    raise SystemExit(0)
try:
    data = json.loads(raw)
except json.JSONDecodeError:
    print("")
    raise SystemExit(0)
items = data if isinstance(data, list) else data.get("decisions") or data.get("items") or []
cutoff = datetime.now(timezone.utc) - timedelta(hours=24)
rows = []
for item in items:
    if not isinstance(item, dict):
        continue
    ip = item.get("value") or item.get("ip") or ""
    scenario = item.get("scenario") or item.get("origin") or "bilinmiyor"
    duration = item.get("duration") or ""
    rows.append((ip, scenario, duration))
if not rows:
    print("")
    raise SystemExit(0)
stamp = datetime.now().astimezone().strftime("%d.%m.%Y %H:%M")
lines = [
    f"🛡️ Gece Saldırı Defteri — {stamp}",
    "",
    f"Son 24 saatte aktif ban: {len(rows)}",
    "",
]
counts = Counter(sc for _, sc, _ in rows)
for scenario, n in counts.most_common(8):
    lines.append(f"• {scenario}: {n}")
lines.append("")
lines.append("Kaynak IP'ler:")
for ip, scenario, duration in rows[:12]:
    extra = f" ({duration})" if duration else ""
    lines.append(f"• {ip} — {scenario}{extra}")
if len(rows) > 12:
    lines.append(f"• … +{len(rows) - 12} daha")
print("\n".join(lines))
PY
)"

[[ -n "${body// }" ]] || { log "ban yok — atlandi"; exit 0; }

body | bash "$ARCHIVE" crowdsec-diary >/dev/null
notify_enabled || exit 0
notify_crowdsec_diary "$body" || true
log "Tamamlandi (${#body} byte)"
