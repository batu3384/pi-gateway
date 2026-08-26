#!/usr/bin/env bash
# Kuma 30g uptime — aylık P3 Telegram (1 mesaj)
set -euo pipefail
REMOTE_DIR="${REMOTE_DIR:-/home/${USER}/pi-gateway}"
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
_PG_ENV_LIB="${SCRIPT_DIR}/../lib/env-file.sh"
PG_SCRIPT_NAME="$(basename "$0")"
# shellcheck source=../lib/env-file.sh
source "${_PG_ENV_LIB:?}"
read_remote_dotenv || { echo "[${PG_SCRIPT_NAME}] HATA: .env dotenv parser hatasi" >&2; exit 1; }
load_telegram_from_hermes || true
# shellcheck source=../lib/notify.sh
source "$SCRIPT_DIR/../lib/notify.sh"

DB="${KUMA_DB:-${REMOTE_DIR}/data/uptime-kuma/kuma.db}"

if [[ "${1:-}" == "--self-check" ]]; then
  python3 - <<'PY'
sql = """
SELECT m.name,
  ROUND(100.0 * SUM(CASE WHEN h.status=1 THEN 1 ELSE 0 END) / COUNT(*), 1)
FROM monitor m JOIN heartbeat h ON h.monitor_id=m.id
WHERE h.time >= datetime('now','-30 day')
GROUP BY m.id ORDER BY 2
"""
assert "30 day" in sql and "heartbeat" in sql
print("[kuma-monthly-report] self-check OK")
PY
  exit 0
fi

notify_enabled || exit 0
[[ -f "$DB" ]] || { echo "[kuma-report] DB yok: $DB" >&2; exit 0; }

body="$(python3 - "$DB" <<'PY'
import sqlite3, sys
from datetime import datetime
db = sys.argv[1]
con = sqlite3.connect(f"file:{db}?mode=ro", uri=True)
sqls = [
    """
    SELECT m.name,
      ROUND(100.0 * SUM(CASE WHEN h.status=1 THEN 1 ELSE 0 END) / COUNT(*), 1) AS pct,
      COUNT(*) AS n
    FROM monitor m
    JOIN heartbeat h ON h.monitor_id = m.id
    WHERE datetime(h.time) >= datetime('now', '-30 day')
    GROUP BY m.id
    ORDER BY pct ASC, m.name
    """,
    """
    SELECT m.name,
      ROUND(100.0 * SUM(CASE WHEN h.status=1 THEN 1 ELSE 0 END) / COUNT(*), 1) AS pct,
      COUNT(*) AS n
    FROM monitor m
    JOIN heartbeats h ON h.monitor_id = m.id
    WHERE datetime(h.time) >= datetime('now', '-30 day')
    GROUP BY m.id
    ORDER BY pct ASC, m.name
    """,
]
rows = []
err = None
for sql in sqls:
    try:
        rows = con.execute(sql).fetchall()
        err = None
        break
    except sqlite3.Error as exc:
        err = exc
con.close()
if err and not rows:
    print("Kuma DB şema okunamadı.")
    raise SystemExit(0)
stamp = datetime.now().astimezone().strftime("%d.%m.%Y")
lines = [f"📋 Pi Gateway · Kuma 30g — {stamp}"]
if not rows:
    lines.append("Heartbeat yok.")
else:
    for name, pct, n in rows[:20]:
        mark = "🟢" if float(pct) >= 99 else ("🟡" if float(pct) >= 95 else "🔴")
        lines.append(f"{mark} {name}: %{pct:g} ({n})")
print("\n".join(lines))
PY
)"

[[ -n "${body// }" ]] || exit 0
notify_send_message "$body" || true
exit 0
