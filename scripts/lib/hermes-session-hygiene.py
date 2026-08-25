#!/usr/bin/env python3
"""Açık şişman/idle Telegram oturumunu kapat — sonraki mesaj yeni session.

Gateway RAM'deki stale satırı state.db end_reason görünce düşürür (#54878);
restart gerekmez. Cron oturumuna dokunma.
"""
from __future__ import annotations

import argparse
import os
import sqlite3
import time
from pathlib import Path

DEFAULT_MAX_MSGS = 200
DEFAULT_QUIET_SEC = 120


def _cols(con: sqlite3.Connection) -> set[str]:
    return {str(r[1]) for r in con.execute("PRAGMA table_info(sessions)")}


def _activity_expr(cols: set[str]) -> str:
    if "last_activity_at" in cols and "started_at" in cols:
        return "COALESCE(last_activity_at, started_at)"
    if "last_activity_at" in cols:
        return "last_activity_at"
    if "started_at" in cols:
        return "started_at"
    return "NULL"


def rotate_sessions(
    db_path: str,
    *,
    max_msgs: int = DEFAULT_MAX_MSGS,
    idle_seconds: int = 0,
    quiet_seconds: int = DEFAULT_QUIET_SEC,
    now: float | None = None,
) -> tuple[list[str], list[str]]:
    ts = time.time() if now is None else now
    con = sqlite3.connect(db_path)
    try:
        con.execute("PRAGMA busy_timeout=3000")
        cols = _cols(con)
        act = _activity_expr(cols)
        open_tg = """
            ended_at IS NULL
            AND COALESCE(archived, 0) = 0
            AND source = 'telegram'
        """
        quiet_ok = f"({act} IS NULL OR {act} <= ?)"
        fat_ids: list[str] = [
            str(r[0])
            for r in con.execute(
                f"""
                SELECT id FROM sessions
                WHERE {open_tg}
                  AND COALESCE(message_count, 0) >= ?
                  AND {quiet_ok}
                """,
                (max_msgs, ts - max(0, quiet_seconds)),
            ).fetchall()
        ]
        idle_ids: list[str] = []
        if idle_seconds > 0:
            fat_set = set(fat_ids)
            idle_ids = [
                str(r[0])
                for r in con.execute(
                    f"""
                    SELECT id FROM sessions
                    WHERE {open_tg}
                      AND {act} IS NOT NULL
                      AND {act} <= ?
                    """,
                    (ts - idle_seconds,),
                ).fetchall()
                if str(r[0]) not in fat_set
            ]
        if fat_ids:
            con.executemany(
                """
                UPDATE sessions
                SET ended_at = ?, end_reason = 'token_hygiene', archived = 1
                WHERE id = ? AND ended_at IS NULL
                """,
                [(ts, i) for i in fat_ids],
            )
        if idle_ids:
            con.executemany(
                """
                UPDATE sessions
                SET ended_at = ?, end_reason = 'token_hygiene_idle', archived = 1
                WHERE id = ? AND ended_at IS NULL
                """,
                [(ts, i) for i in idle_ids],
            )
        if fat_ids or idle_ids:
            con.commit()
        return fat_ids, idle_ids
    finally:
        con.close()


def rotate_fat_sessions(
    db_path: str,
    *,
    max_msgs: int = DEFAULT_MAX_MSGS,
    now: float | None = None,
) -> list[str]:
    fat, _idle = rotate_sessions(db_path, max_msgs=max_msgs, idle_seconds=0, quiet_seconds=0, now=now)
    return fat


def _self_check() -> None:
    import tempfile

    path = Path(tempfile.mkdtemp()) / "state.db"
    con = sqlite3.connect(path)
    con.execute(
        """
        CREATE TABLE sessions (
            id TEXT, source TEXT, message_count INT,
            ended_at REAL, end_reason TEXT, archived INT,
            last_activity_at REAL, started_at REAL
        )
        """
    )
    now = 1_000_000.0
    con.executemany(
        "INSERT INTO sessions VALUES (?,?,?,?,?,?,?,?)",
        [
            ("fat", "telegram", 790, None, None, 0, now - 600, now - 9000),
            ("hot", "telegram", 250, None, None, 0, now - 10, now - 400),
            ("ok", "telegram", 40, None, None, 0, now - 50, now - 80),
            ("idle", "telegram", 12, None, None, 0, now - 50_000, now - 80_000),
            ("cron", "cron", 900, None, None, 0, now - 50_000, now - 80_000),
            ("old", "telegram", 500, 1.0, "user", 1, now - 50_000, now - 80_000),
        ],
    )
    con.commit()
    con.close()
    fat, idle = rotate_sessions(
        str(path), max_msgs=200, idle_seconds=12 * 3600, quiet_seconds=120, now=now
    )
    assert fat == ["fat"], fat
    assert idle == ["idle"], idle
    con = sqlite3.connect(path)
    rows = {r[0]: r[1:] for r in con.execute(
        "SELECT id, ended_at, end_reason, archived FROM sessions"
    )}
    con.close()
    assert rows["fat"][0] == now and rows["fat"][1] == "token_hygiene"
    assert rows["hot"][0] is None
    assert rows["ok"][0] is None
    assert rows["idle"][0] == now and rows["idle"][1] == "token_hygiene_idle"
    assert rows["cron"][0] is None
    assert rows["old"][1] == "user"
    print("[hermes-session-hygiene] self-check OK")


def main() -> int:
    ap = argparse.ArgumentParser()
    ap.add_argument("--self-check", action="store_true")
    ap.add_argument("--db", default="")
    ap.add_argument(
        "--max-msgs",
        type=int,
        default=int(os.environ.get("HERMES_SESSION_ROTATE_MSGS", str(DEFAULT_MAX_MSGS))),
    )
    ap.add_argument(
        "--idle-seconds",
        type=int,
        default=int(os.environ.get("HERMES_SESSION_IDLE_SEC", "0")),
    )
    ap.add_argument(
        "--quiet-seconds",
        type=int,
        default=int(os.environ.get("HERMES_SESSION_QUIET_SEC", str(DEFAULT_QUIET_SEC))),
    )
    args = ap.parse_args()
    if args.self_check:
        _self_check()
        return 0
    db = args.db or os.path.expanduser("~/.hermes/state.db")
    if not Path(db).is_file():
        print("[hermes-session-hygiene] state.db yok — atlandi")
        return 0
    fat, idle = rotate_sessions(
        db,
        max_msgs=args.max_msgs,
        idle_seconds=args.idle_seconds,
        quiet_seconds=args.quiet_seconds,
    )
    if fat:
        print("[hermes-session-hygiene] closed_fat=" + ",".join(fat))
    if idle:
        print("[hermes-session-hygiene] closed_idle=" + ",".join(idle))
    if not fat and not idle:
        print("[hermes-session-hygiene] sisman/idle acik telegram oturumu yok")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
