#!/usr/bin/env python3
"""Açık Telegram oturumu çok şiştiyse SLO satırı (systemd FAIL değil)."""
from __future__ import annotations

import os
import sqlite3
import sys
from pathlib import Path

DEFAULT_MAX_MSGS = 250


def fat_lines(rows: list[tuple], max_msgs: int) -> list[str]:
    out: list[str] = []
    for sid, count in rows:
        n = int(count or 0)
        if n >= max_msgs:
            out.append(f"hermes-session-fat:{sid}({n})")
    return out


def main() -> int:
    db = Path(
        sys.argv[1]
        if len(sys.argv) > 1 and not sys.argv[1].startswith("-")
        else os.path.expanduser("~/.hermes/state.db")
    )
    if not db.is_file():
        return 0
    max_msgs = int(os.environ.get("HERMES_SESSION_SLO_MSGS", str(DEFAULT_MAX_MSGS)))
    con = sqlite3.connect(f"file:{db}?mode=ro", uri=True)
    try:
        rows = con.execute(
            """
            SELECT id, message_count FROM sessions
            WHERE ended_at IS NULL AND COALESCE(archived, 0) = 0
              AND source = 'telegram'
            """
        ).fetchall()
    finally:
        con.close()
    for line in fat_lines(rows, max_msgs):
        print(line)
    return 0


def _self_check() -> None:
    lines = fat_lines([("a", 790), ("b", 40), ("c", None)], 250)
    assert lines == ["hermes-session-fat:a(790)"], lines
    assert fat_lines([("x", 250)], 250) == ["hermes-session-fat:x(250)"]
    print("[hermes-token-slo] self-check OK")


if __name__ == "__main__":
    if "--self-check" in sys.argv:
        _self_check()
        raise SystemExit(0)
    raise SystemExit(main())
