#!/usr/bin/env python3
"""Bülten post: iskelet, arşiv, 4096 split (kelime kesme yok)."""
from __future__ import annotations

import json
import os
import re
import sys
import urllib.error
import urllib.parse
import urllib.request
from datetime import datetime
from pathlib import Path

TG_LIMIT = 4096
SEP = "─────────"
SKELETON_MARKERS = ("Pi Gateway · Bülten", SEP)
TITLE_RE = re.compile(r"^(?:[0-9]+[).]|[🤖💻🔬🚀⚡📌])\s+(.+)$")


def archive_dir() -> Path:
    env = os.environ.get("BULLETIN_ARCHIVE_DIR")
    candidates = []
    if env:
        candidates.append(Path(env))
    candidates.extend(
        (
            Path("/var/lib/pi-gateway/bulletins"),
            Path.home() / ".hermes" / "bulletins",
            Path("/tmp/pi-gateway-bulletins"),
        )
    )
    for d in candidates:
        try:
            d.mkdir(parents=True, exist_ok=True)
            if os.access(d, os.W_OK):
                return d
        except OSError:
            continue
    return Path("/tmp/pi-gateway-bulletins")


def has_skeleton(text: str) -> bool:
    body = (text or "").strip()
    return all(m in body for m in SKELETON_MARKERS)


def extract_titles(text: str) -> list[str]:
    out: list[str] = []
    for line in (text or "").splitlines():
        m = TITLE_RE.match(line.strip())
        if not m:
            continue
        title = m.group(1).strip()
        if title and title not in out:
            out.append(title[:120])
    return out


def recent_titles(limit: int = 24) -> str:
    d = archive_dir()
    files = sorted(d.glob("*.md"), key=lambda p: p.stat().st_mtime, reverse=True)[:12]
    titles: list[str] = []
    seen: set[str] = set()
    for path in files:
        try:
            body = path.read_text(encoding="utf-8")
        except OSError:
            continue
        for t in extract_titles(body):
            key = t.lower()
            if key in seen:
                continue
            seen.add(key)
            titles.append(t)
            if len(titles) >= limit:
                return "\n".join(f"- {x}" for x in titles)
    if not titles:
        return "(yok)"
    return "\n".join(f"- {x}" for x in titles)


def _split_chunk(text: str, limit: int) -> tuple[str, str]:
    if len(text) <= limit:
        return text, ""
    window = text[:limit]
    for needle in (f"\n{SEP}\n", "\n\n", "\n"):
        idx = window.rfind(needle)
        if idx >= max(40, limit // 5):
            return text[: idx + 1].rstrip(), text[idx + len(needle) :].lstrip()
    idx = window.rfind(" ")
    if idx > limit // 2:
        return text[:idx].rstrip(), text[idx + 1 :].lstrip()
    return text[:limit], text[limit:]


def split_parts(text: str, limit: int = TG_LIMIT) -> list[str]:
    text = (text or "").strip()
    if not text:
        return []
    if len(text) <= limit:
        return [text]
    reserve = 10  # "(1/2)\n"
    budget = limit - reserve
    chunks: list[str] = []
    rest = text
    while rest:
        if len(rest) <= budget:
            chunks.append(rest)
            break
        head, rest = _split_chunk(rest, budget)
        if not head:
            head, rest = rest[:budget], rest[budget:]
        chunks.append(head)
    n = len(chunks)
    if n == 1:
        return chunks
    return [f"({i}/{n})\n{c}" for i, c in enumerate(chunks, 1)]


def archive(text: str, slug: str) -> Path | None:
    slug = re.sub(r"[^a-zA-Z0-9._-]+", "_", slug or "note")[:40]
    path = archive_dir() / f"{datetime.now().astimezone().strftime('%Y-%m-%d-%H%M')}-{slug}.md"
    try:
        path.write_text(text.rstrip() + "\n", encoding="utf-8")
        return path
    except OSError:
        return None


def _send_telegram(text: str) -> bool:
    token = os.environ.get("TELEGRAM_BOT_TOKEN") or ""
    chat = os.environ.get("TELEGRAM_CHAT_ID") or ""
    if not token or not chat:
        return False
    url = f"https://api.telegram.org/bot{token}/sendMessage"
    payload = urllib.parse.urlencode(
        {
            "chat_id": chat,
            "text": text,
            "disable_web_page_preview": "true",
        }
    ).encode()
    req = urllib.request.Request(url, data=payload, method="POST")
    try:
        with urllib.request.urlopen(req, timeout=20) as resp:
            data = json.load(resp)
        return bool(data.get("ok"))
    except (OSError, TimeoutError, json.JSONDecodeError, urllib.error.URLError):
        return False


def slug_for_job(name: str) -> str:
    n = (name or "").lower()
    if "piyasa" in n:
        return "fx"
    if "günaydın" in n or "gunaydin" in n or "07:00" in n:
        return "sabah"
    if "23" in n or "bilim" in n or "teknoloji" in n:
        return "bilim"
    if "gündem" in n or "gundem" in n or "akşam" in n or "aksam" in n:
        return "gundem"
    return "bulten"


def prepare(text: str, job_name: str = "", *, send_rest: bool = True) -> dict:
    """İskelet yoksa skip. Arşiv + split. rest Telegram'a (ilk parça Hermes'e)."""
    body = (text or "").rstrip()
    slug = slug_for_job(job_name)
    if not has_skeleton(body):
        return {"skip": True, "first": None, "rest": [], "reason": "no-skeleton"}
    archive(body, slug)
    parts = split_parts(body)
    first = parts[0] if parts else None
    rest = parts[1:]
    if send_rest:
        for chunk in rest:
            _send_telegram(chunk)
    return {"skip": False, "first": first, "rest": rest, "reason": ""}


def self_check() -> None:
    assert has_skeleton("📋 Pi Gateway · Bülten\n─────────\nMerhaba\n─────────")
    assert not has_skeleton("sadece metin")
    titles = extract_titles("1) Alfa haber\n2) Beta")
    assert titles == ["Alfa haber", "Beta"], titles
    long = "📋 Pi Gateway · Bülten\n─────────\n" + ("haber " * 800) + "\n─────────\nPi Gateway"
    parts = split_parts(long, limit=400)
    assert len(parts) >= 2, len(parts)
    assert parts[0].startswith("(1/")
    assert all(len(p) <= 400 for p in parts), [len(p) for p in parts]
    tiny = split_parts("kısa", limit=400)
    assert tiny == ["kısa"]
    print("[bulletin-post] self-check OK")


def main() -> int:
    if "--self-check" in sys.argv:
        self_check()
        return 0
    if "--titles" in sys.argv:
        print(recent_titles())
        return 0
    body = sys.stdin.read()
    job = ""
    if "--prepare" in sys.argv:
        idx = sys.argv.index("--prepare")
        job = sys.argv[idx + 1] if idx + 1 < len(sys.argv) else ""
        send = "--no-send" not in sys.argv
        out = prepare(body, job, send_rest=send)
        json.dump(out, sys.stdout, ensure_ascii=False)
        sys.stdout.write("\n")
        return 0 if not out.get("skip") else 2
    slug = sys.argv[1] if len(sys.argv) > 1 else "note"
    archive(body, slug)
    sys.stdout.write(body)
    if body and not body.endswith("\n"):
        sys.stdout.write("\n")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
