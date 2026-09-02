#!/usr/bin/env python3
"""CrowdSec decisions JSON (stdin) → gece defteri metni."""
from __future__ import annotations

import json
import sys
from collections import Counter
from datetime import datetime


def format_diary(raw: str) -> str:
    raw = raw.strip()
    if not raw:
        return ""
    try:
        data = json.loads(raw)
    except json.JSONDecodeError:
        return ""
    items = data if isinstance(data, list) else data.get("decisions") or data.get("items") or []
    rows: list[tuple[str, str, str]] = []
    for item in items:
        if not isinstance(item, dict):
            continue
        ip = str(item.get("value") or item.get("ip") or "")
        scenario = str(item.get("scenario") or item.get("origin") or "bilinmiyor")
        duration = str(item.get("duration") or "")
        rows.append((ip, scenario, duration))
    if not rows:
        return ""
    stamp = datetime.now().astimezone().strftime("%d.%m.%Y %H:%M")
    lines = [
        f"🛡️ Gece Saldırı Defteri — {stamp}",
        "",
        f"Aktif ban: {len(rows)}",
        "",
    ]
    for scenario, n in Counter(sc for _, sc, _ in rows).most_common(8):
        lines.append(f"• {scenario}: {n}")
    lines.append("")
    lines.append("Kaynak IP'ler:")
    for ip, scenario, duration in rows[:12]:
        extra = f" ({duration})" if duration else ""
        lines.append(f"• {ip} — {scenario}{extra}")
    if len(rows) > 12:
        lines.append(f"• … +{len(rows) - 12} daha")
    return "\n".join(lines)


def main() -> int:
    print(format_diary(sys.stdin.read()), end="")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
