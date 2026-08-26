#!/usr/bin/env python3
"""Hermes cron jobs.json — repo şablonunu canlı job kayıtlarıyla birleştir."""
from __future__ import annotations

import argparse
import fcntl
import json
import secrets
import sys
from copy import deepcopy
from datetime import datetime, timezone
from pathlib import Path
from typing import Any

MERGE_KEYS = (
    "prompt",
    "no_agent",
    "script",
    "enabled_toolsets",
    "context_from",
    "reasoning_effort",
    "schedule",
    "schedule_display",
    "deliver",
    "enabled",
    "skills",
    "skill",
)


def _recent_titles() -> str:
    post = Path(__file__).with_name("bulletin-post.py")
    try:
        import importlib.util

        spec = importlib.util.spec_from_file_location("bulletin_post", post)
        if spec is None or spec.loader is None:
            return "(yok)"
        mod = importlib.util.module_from_spec(spec)
        spec.loader.exec_module(mod)
        return str(mod.recent_titles() or "(yok)")
    except Exception:
        return "(yok)"


def _subst(text: str | None, remote_dir: str, pi_user: str, titles: str | None = None) -> str | None:
    if text is None:
        return None
    out = (
        text.replace("__REMOTE_DIR__", remote_dir)
        .replace("__PI_USER__", pi_user)
        .replace("/home/PI_USER", f"/home/{pi_user}")
    )
    if "__BULLETIN_RECENT_TITLES__" in out:
        out = out.replace("__BULLETIN_RECENT_TITLES__", titles if titles is not None else _recent_titles())
    return out


def _merge_job(live: dict[str, Any], spec: dict[str, Any], remote_dir: str, pi_user: str, titles: str | None = None) -> bool:
    changed = False
    for key in MERGE_KEYS:
        if key not in spec:
            continue
        val = spec[key]
        if key == "prompt":
            val = _subst(val, remote_dir, pi_user, titles)
        elif key == "script" and val and ("__REMOTE_DIR__" in str(val) or str(val).startswith("/")):
            val = _subst(val, remote_dir, pi_user, titles)
        if live.get(key) != val:
            live[key] = val
            changed = True
    if spec.get("no_agent") and live.get("prompt"):
        live["prompt"] = ""
        changed = True
    return changed


def _spawn_job(spec: dict[str, Any], sibling: dict[str, Any], remote_dir: str, pi_user: str, titles: str | None = None) -> dict[str, Any]:
    now = datetime.now(timezone.utc).astimezone().isoformat()
    job = deepcopy(spec)
    job["prompt"] = _subst(job.get("prompt"), remote_dir, pi_user, titles)
    job["script"] = _subst(job.get("script"), remote_dir, pi_user, titles)
    job["id"] = secrets.token_hex(6)
    for key in ("origin", "provider_snapshot", "model_snapshot", "deliver"):
        if key not in job and key in sibling:
            job[key] = deepcopy(sibling[key])
    job.setdefault("enabled", True)
    job.setdefault("state", "scheduled")
    job.setdefault("deliver", "origin")
    job.setdefault("skills", [])
    job.setdefault("skill", None)
    job.setdefault("provider", None)
    job.setdefault("model", None)
    job.setdefault("base_url", None)
    job.setdefault("monitor_script", None)
    job.setdefault("monitor_url", None)
    job.setdefault("monitor_state", None)
    job.setdefault("workdir", None)
    job.setdefault("fire_claim", None)
    job["created_at"] = now
    job["next_run_at"] = None
    job["last_run_at"] = None
    job["last_error"] = None
    job["last_delivery_error"] = None
    job["failure_streak"] = 0
    job["paused_at"] = None
    job["paused_reason"] = None
    job["repeat"] = {"times": None, "completed": 0}
    return job


def merge(
    template: dict[str, Any],
    live_path: Path,
    remote_dir: str,
    pi_user: str,
) -> tuple[dict[str, Any], int]:
    if live_path.is_file():
        live_doc = json.loads(live_path.read_text(encoding="utf-8"))
    else:
        live_doc = {"jobs": []}

    titles = _recent_titles()
    specs = {j["name"]: j for j in template.get("jobs", []) if j.get("name")}
    by_name = {j.get("name"): j for j in live_doc.get("jobs", [])}
    changed = 0
    tmpl_jobs = template.get("jobs") or []
    template_sibling = next(
        (j for j in tmpl_jobs if not j.get("no_agent")),
        tmpl_jobs[0] if tmpl_jobs else None,
    )
    sibling = live_doc["jobs"][0] if live_doc.get("jobs") else (template_sibling or {"deliver": "origin"})

    for name, spec in specs.items():
        if name in by_name:
            if _merge_job(by_name[name], spec, remote_dir, pi_user, titles):
                changed += 1
        else:
            live_doc.setdefault("jobs", []).append(
                _spawn_job(spec, sibling, remote_dir, pi_user, titles)
            )
            changed += 1

    # Template SSOT: drop retired pi-gateway jobs (script basename OR known names)
    retired_scripts = {"pi-watchdog.sh", "pi-netalert-newdev.sh", "pi-netalert-offline.sh"}
    retired_names = {
        "Pi Sistem Gözcüsü (saatlik)",
        "Ağ Gözcüsü — Yeni Cihaz (15dk)",
        "Ağ Gözcüsü — Offline (30dk)",
    }
    kept: list[dict[str, Any]] = []
    for job in live_doc.get("jobs") or []:
        script = str(job.get("script") or "").rsplit("/", 1)[-1]
        name = job.get("name")
        # Rename edilmis olsa bile retired script → sil
        if script in retired_scripts:
            changed += 1
            continue
        if name not in specs and name in retired_names:
            changed += 1
            continue
        kept.append(job)
    live_doc["jobs"] = kept

    live_doc["updated_at"] = datetime.now(timezone.utc).astimezone().isoformat()
    return live_doc, changed


_TIMEOUT_90 = ("timed out after 90", "timeout after 90s")


def reset_legacy_timeout_streaks(doc: dict[str, Any]) -> int:
    """90s stale timeout leftover — streak sıfırla; 300s hatasına dokunma."""
    n = 0
    for job in doc.get("jobs") or []:
        err = str(job.get("last_error") or "").lower()
        if not any(needle in err for needle in _TIMEOUT_90):
            continue
        job["failure_streak"] = 0
        job["last_error"] = None
        n += 1
    return n


def main() -> int:
    ap = argparse.ArgumentParser()
    ap.add_argument("--template", required=True)
    ap.add_argument("--live", required=True)
    ap.add_argument("--remote-dir", required=True)
    ap.add_argument("--pi-user", required=True)
    ap.add_argument("--dry-run", action="store_true")
    args = ap.parse_args()

    template = json.loads(Path(args.template).read_text(encoding="utf-8"))
    live_path = Path(args.live)

    lock_path = live_path.with_suffix(".lock")
    with open(lock_path, "w", encoding="utf-8") as lockf:
        fcntl.flock(lockf, fcntl.LOCK_EX)
        merged, n = merge(template, live_path, args.remote_dir, args.pi_user)
        reset_n = reset_legacy_timeout_streaks(merged)

        if args.dry_run:
            print(f"would_update={n} timeout_streak_reset={reset_n}")
            return 0

        backup = live_path.with_suffix(".json.bak")
        if live_path.is_file():
            backup.write_text(live_path.read_text(encoding="utf-8"), encoding="utf-8")
        tmp = live_path.with_suffix(".json.tmp")
        tmp.write_text(json.dumps(merged, ensure_ascii=False, indent=2) + "\n", encoding="utf-8")
        tmp.replace(live_path)
        print(f"[hermes-cron] guncellenen job: {n} timeout_streak_reset={reset_n}")
    return 0


def _self_check() -> None:
    template = {
        "jobs": [
            {
                "name": "Test Job",
                "schedule": {"kind": "cron", "expr": "0 * * * *", "display": "0 * * * *"},
                "schedule_display": "0 * * * *",
                "deliver": "origin",
                "enabled": True,
                "no_agent": True,
                "script": "pi-fx-quote.sh",
                "prompt": "",
                "enabled_toolsets": [],
                "context_from": None,
            }
        ]
    }
    import tempfile

    with tempfile.TemporaryDirectory() as td:
        live = Path(td) / "jobs.json"
        merged, n = merge(template, live, "/home/pi/pi-gateway", "pi")
        assert len(merged["jobs"]) == 1, merged
        assert n == 1
        # Retired script (renamed job) + retired name → prune
        live.write_text(
            json.dumps(
                {
                    "jobs": [
                        merged["jobs"][0],
                        {
                            "name": "Custom Watchdog",
                            "script": "/x/pi-watchdog.sh",
                            "enabled": True,
                        },
                        {
                            "name": "Pi Sistem Gözcüsü (saatlik)",
                            "script": "other.sh",
                            "enabled": True,
                        },
                    ]
                },
                ensure_ascii=False,
                indent=2,
            ),
            encoding="utf-8",
        )
        pruned, n_prune = merge(template, live, "/home/pi/pi-gateway", "pi")
        assert len(pruned["jobs"]) == 1, pruned
        assert pruned["jobs"][0]["name"] == "Test Job"
        assert n_prune >= 2
        empty = Path(td) / "empty.json"
        merged_empty, n_empty = merge(template, empty, "/home/pi/pi-gateway", "pi")
        assert len(merged_empty["jobs"]) == 1, merged_empty
        assert n_empty == 1
    stale = {
        "jobs": [
            {
                "name": "Akşam 7",
                "last_error": "RuntimeError: Non-streaming API call timed out after 90s",
                "failure_streak": 1,
            },
            {
                "name": "ok",
                "last_error": "timed out after 300s",
                "failure_streak": 2,
            },
        ]
    }
    assert reset_legacy_timeout_streaks(stale) == 1
    assert stale["jobs"][0]["failure_streak"] == 0
    assert stale["jobs"][0]["last_error"] is None
    assert stale["jobs"][1]["failure_streak"] == 2
    print("[hermes-cron-merge] self-check OK")


if __name__ == "__main__":
    if "--self-check" in sys.argv:
        _self_check()
        raise SystemExit(0)
    raise SystemExit(main())
