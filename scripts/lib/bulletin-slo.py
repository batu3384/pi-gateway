#!/usr/bin/env python3
"""Hermes 07/19/23 last_run > 26h → SLO satırı (systemd FAIL değil)."""
from __future__ import annotations

import json
import os
import sys
from datetime import datetime, timezone
from pathlib import Path
from typing import Any

WANT_EXPR = {"0 7 * * *", "0 19 * * *", "0 23 * * *"}
DEFAULT_MAX_H = 26


def _parse_ts(raw: Any) -> float | None:
    if not raw:
        return None
    try:
        return datetime.fromisoformat(str(raw).replace("Z", "+00:00")).timestamp()
    except (TypeError, ValueError):
        return None


def last_run_ts(job: dict[str, Any]) -> float | None:
    for key in ("last_run", "last_run_at", "last_success_at"):
        ts = _parse_ts(job.get(key))
        if ts is not None:
            return ts
    return None


def stale_lines(jobs: list[Any], now: float, max_age_s: float) -> list[str]:
    out: list[str] = []
    for job in jobs:
        if not isinstance(job, dict):
            continue
        if job.get("no_agent") or not job.get("enabled", True):
            continue
        expr = (job.get("schedule") or {}).get("expr") or ""
        if expr not in WANT_EXPR:
            continue
        ts = last_run_ts(job)
        name = job.get("name") or expr
        if ts is None:
            created = None
            for key in ("created_at", "spawned_at"):
                created = _parse_ts(job.get(key))
                if created is not None:
                    break
            # created yok = eski kayıt; yeni spawn created_at yazar, 26s gürültü yok
            if created is None or now - created > max_age_s:
                out.append(f"bulletin-stale:{name}(never)")
            continue
        age = now - ts
        if age > max_age_s:
            hours = int(age // 3600)
            out.append(f"bulletin-stale:{name}({hours}h)")
    return out


def main() -> int:
    path = Path(
        sys.argv[1]
        if len(sys.argv) > 1 and not sys.argv[1].startswith("-")
        else os.path.expanduser("~/.hermes/cron/jobs.json")
    )
    if not path.is_file():
        return 0
    max_h = int(os.environ.get("BULLETIN_SLO_MAX_AGE_H", str(DEFAULT_MAX_H)))
    doc = json.loads(path.read_text(encoding="utf-8"))
    now = datetime.now(timezone.utc).timestamp()
    for line in stale_lines(doc.get("jobs") or [], now, max_h * 3600):
        print(line)
    return 0


def _self_check() -> None:
    now = datetime(2026, 8, 25, tzinfo=timezone.utc).timestamp()
    jobs: list[dict[str, Any]] = [
        {
            "name": "Akşam 7",
            "enabled": True,
            "no_agent": False,
            "schedule": {"expr": "0 19 * * *"},
            "last_run": "2026-08-23T19:00:00+03:00",
        },
        {
            "name": "Gece",
            "enabled": True,
            "no_agent": False,
            "schedule": {"expr": "0 23 * * *"},
            "last_run_at": "2026-08-24T23:00:00+03:00",
        },
        {
            "name": "skip-no-agent",
            "enabled": True,
            "no_agent": True,
            "schedule": {"expr": "0 19 * * *"},
            "last_run": "2026-08-01T00:00:00+00:00",
        },
        {
            "name": "Hiç",
            "enabled": True,
            "no_agent": False,
            "schedule": {"expr": "0 7 * * *"},
            "created_at": "2026-08-20T07:00:00+03:00",
        },
        {
            "name": "Yeni",
            "enabled": True,
            "no_agent": False,
            "schedule": {"expr": "0 7 * * *"},
            "created_at": "2026-08-24T23:00:00+03:00",
        },
        {
            "name": "NoMeta",
            "enabled": True,
            "no_agent": False,
            "schedule": {"expr": "0 7 * * *"},
        },
    ]
    lines = stale_lines(jobs, now, 26 * 3600)
    assert any("Akşam 7" in x for x in lines), lines
    assert not any("Gece" in x for x in lines), lines
    assert not any("skip" in x for x in lines), lines
    assert any("Hiç(never)" in x for x in lines), lines
    assert not any("Yeni" in x for x in lines), lines
    assert any("NoMeta(never)" in x for x in lines), lines
    print("[bulletin-slo] self-check OK")


if __name__ == "__main__":
    if "--self-check" in sys.argv:
        _self_check()
        raise SystemExit(0)
    raise SystemExit(main())
