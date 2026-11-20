#!/usr/bin/env python3
"""Jarvis bülten rutinlerini OpenBot sqlite'a yazar.

OpenBot duruyken --apply. --check çıkışı: 0 senkron, 10 fark var.
"""
from __future__ import annotations

import json
import os
import sqlite3
import sys
import uuid
from datetime import datetime, timedelta, timezone
from pathlib import Path
from zoneinfo import ZoneInfo

TZ_NAME = "Europe/Istanbul"
NS = uuid.UUID("6d0f3e6e-047a-4ec0-9697-d093cf953716")

SPECS = (
    {
        "key": "morning",
        "name": "Günaydın Panosu",
        "match": "Günaydın Panosu (07:00)",
        "time": "07:00",
    },
    {
        "key": "fx",
        "name": "Piyasa Özeti",
        "match": None,
        "time": "18:55",
    },
    {
        "key": "evening",
        "name": "Akşam Gündem",
        "match": "Akşam 7 Gündem Bülteni (TR + Dünya)",
        "time": "19:00",
    },
    {
        "key": "night",
        "name": "Gece Teknoloji",
        "match": "Gece 23 Teknoloji & Bilim Bülteni",
        "time": "23:00",
    },
)


def repo_dir() -> Path:
    return Path(__file__).resolve().parents[2]


def db_path() -> Path:
    state = os.environ.get("OPENBOT_STATE_DIR")
    if state:
        return Path(state) / "openbot.db"
    root = Path(os.environ.get("OPENBOT_DATA_ROOT", "/mnt/ssd/openbot-native"))
    return root / "config/OpenBot/openbot.db"


def next_daily(hhmm: str, now: datetime) -> str:
    hour, minute = (int(part) for part in hhmm.split(":"))
    tz = ZoneInfo(TZ_NAME)
    local = now.astimezone(tz)
    cand = local.replace(hour=hour, minute=minute, second=0, microsecond=0)
    if cand <= local:
        cand += timedelta(days=1)
    return cand.astimezone(timezone.utc).strftime("%Y-%m-%dT%H:%M:%S.000Z")


def prompt_for(spec: dict) -> str:
    if spec["key"] == "fx":
        return (
            "Piyasa özeti (18:55, Europe/Istanbul). Rakam uydurmak yasak.\n"
            "1) Varsa çalıştır ve stdout'u olduğu gibi gönder:\n"
            "REMOTE_DIR=/pi-gateway bash /pi-gateway/scripts/pi/fx-quote.sh\n"
            "2) Komut yoksa dosyayı oku ve içeriği tek mesaj yap:\n"
            f"{os.environ.get('OPENBOT_DATA_ROOT', '/mnt/ssd/openbot-native')}/pi-gateway-fx-latest.txt\n"
            "Dosya yok, boş veya 3 saatten eskiyse yalnızca «Piyasa verisi yok» yaz.\n"
            "HTML yok. Kur, altın veya endeks tahmini ekleme."
        )
    data = json.loads(
        (repo_dir() / "config/hermes/cron-jobs.template.json").read_text(
            encoding="utf-8"
        )
    )
    prompt = ""
    for job in data.get("jobs", []):
        if job.get("name") == spec["match"]:
            prompt = job.get("prompt") or ""
            break
    if not prompt:
        raise SystemExit(f"şablon prompt yok: {spec['match']}")
    prompt = prompt.replace("__BULLETIN_RECENT_TITLES__", "(yok — önceki başlığı güncellemeden tekrarlama)")
    prompt = prompt.replace("TELEGRAM:", "ÇIKTI:")
    prompt = prompt.replace("TELEGRAM ", "")
    return (
        f"[pi-gateway-routine:{spec['key']}]\n"
        "OpenBot Jarvis rutini. Tek mesaj, Türkçe, taranabilir. Web araması serbest.\n\n"
        + prompt
    )


def desired(now: datetime) -> list[dict]:
    rows = []
    for spec in SPECS:
        schedule = {"kind": "daily", "time": spec["time"]}
        rows.append(
            {
                "id": str(uuid.uuid5(NS, spec["key"])),
                "name": spec["name"],
                "instruction": prompt_for(spec),
                "schedule": schedule,
                "schedule_json": json.dumps(schedule, separators=(",", ":")),
                "next_run_at": next_daily(spec["time"], now),
            }
        )
    return rows


def jarvis_id(con: sqlite3.Connection) -> str:
    rows = [
        json.loads(blob)
        for (blob,) in con.execute("select agent_json from projection_agents")
    ]
    match = [a for a in rows if a.get("name") == "Jarvis"]
    if len(match) == 1:
        return match[0]["id"]
    if len(rows) == 1:
        return rows[0]["id"]
    raise SystemExit("Jarvis agent bulunamadı")


def load_current(con: sqlite3.Connection, agent_id: str) -> dict[str, dict]:
    found: dict[str, dict] = {}
    query = """
      select r.routine_id, r.name, r.instruction, r.active, r.timezone,
             r.limit_policy, r.missed_policy, r.run_in, t.schedule_json
      from projection_agent_routines r
      left join projection_routine_triggers t on t.routine_id = r.routine_id
      where r.agent_id = ?
    """
    for row in con.execute(query, (agent_id,)):
        found[row[1]] = {
            "id": row[0],
            "instruction": row[2],
            "active": row[3],
            "timezone": row[4],
            "limit_policy": row[5],
            "missed_policy": row[6],
            "run_in": row[7],
            "schedule_json": row[8],
        }
    return found


def dirty(current: dict[str, dict], want: list[dict]) -> bool:
    for item in want:
        have = current.get(item["name"])
        if not have:
            return True
        if have["instruction"] != item["instruction"]:
            return True
        if have["active"] != 1 or have["timezone"] != TZ_NAME:
            return True
        if have["limit_policy"] != "wait" or have["missed_policy"] != "run-once":
            return True
        if have["run_in"] != "chat":
            return True
        if have["schedule_json"] != item["schedule_json"]:
            return True
    return False


def apply(con: sqlite3.Connection, agent_id: str, want: list[dict], now: datetime) -> None:
    stamp = now.astimezone(timezone.utc).strftime("%Y-%m-%dT%H:%M:%S.000Z")
    seq = con.execute("select coalesce(max(sequence),0) from orchestration_events").fetchone()[0]
    for item in want:
        have = con.execute(
            "select routine_id from projection_agent_routines where agent_id = ? and name = ?",
            (agent_id, item["name"]),
        ).fetchone()
        routine_id = have[0] if have else item["id"]
        if have:
            con.execute(
                """update projection_agent_routines
                   set instruction=?, active=1, timezone=?, limit_policy='wait',
                       missed_policy='run-once', run_in='chat', updated_at=?,
                       last_event_sequence=?
                   where routine_id=?""",
                (item["instruction"], TZ_NAME, stamp, seq, routine_id),
            )
            con.execute(
                "delete from projection_routine_triggers where routine_id=?",
                (routine_id,),
            )
        else:
            con.execute(
                """insert into projection_agent_routines (
                     routine_id, agent_id, name, instruction, active, timezone,
                     created_at, updated_at, last_event_sequence, limit_policy,
                     missed_policy, run_in
                   ) values (?, ?, ?, ?, 1, ?, ?, ?, ?, 'wait', 'run-once', 'chat')""",
                (
                    routine_id,
                    agent_id,
                    item["name"],
                    item["instruction"],
                    TZ_NAME,
                    stamp,
                    stamp,
                    seq,
                ),
            )
        con.execute(
            """insert into projection_routine_triggers (
                 trigger_id, routine_id, schedule_json, next_run_at,
                 created_at, updated_at, last_event_sequence
               ) values (?, ?, ?, ?, ?, ?, ?)""",
            (
                str(uuid.uuid4()),
                routine_id,
                item["schedule_json"],
                item["next_run_at"],
                stamp,
                stamp,
                seq,
            ),
        )
    con.commit()


def main() -> None:
    print(
        "Jarvis bülten senkronu kapatıldı. Rutinler: sync-fleet-routines.py",
        file=sys.stderr,
    )
    raise SystemExit(0)


if __name__ == "__main__":
    main()
