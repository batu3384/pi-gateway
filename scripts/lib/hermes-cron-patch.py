#!/usr/bin/env python3
"""Pi Gateway — Hermes scheduler.py yamalari (idempotent)."""
from __future__ import annotations

import pathlib
import sys

_FAILURE_END = '    return f"⚠️ Cron \'{job_name}\' failed: {cleaned}"'

_FAILURE_V7 = '''    # pi-gateway: cron failure v7
    if not job.get("no_agent"):
        if "timed out after" in lower or "non-streaming api" in lower or (
            "stale" in lower and "timeout" in lower
        ):
            return (
                "📋 Bülten\\n\\n"
                f"Görev: {job_name}\\n"
                "Sorun: Model yanıtı zaman aşımına uğradı.\\n"
                "Bu tur üretilemedi. Sonraki planlı tur otomatik dener.\\n"
                "Piyasa özeti 18:55 ayrı gider."
            )
        if "firecrawl" in lower and ("403" in lower or "forbidden" in lower):
            return (
                "📋 Bülten\\n\\n"
                f"Görev: {job_name}\\n"
                "Sorun: Web arama hizmeti erişimi reddetti.\\n"
                "Bu tur üretilemedi. Sonraki tur otomatik dener.\\n"
                "Ne yapmalı? Arama motoru ayarını (ddgs) kontrol edin."
            )
        if (
            "http 400" in lower
            or "potentially unsafe" in lower
            or "sensitive content" in lower
        ):
            return (
                "📋 Bülten\\n\\n"
                f"Görev: {job_name}\\n"
                "Sorun: Model sağlayıcı güvenlik filtresi.\\n"
                "Bu tur üretilemedi. Sonraki planlı tur otomatik dener.\\n"
                "Piyasa özeti 18:55 ayrı gider."
            )
        if "http 429" in lower or "rate limit" in lower:
            return (
                "📋 Bülten\\n\\n"
                f"Görev: {job_name}\\n"
                "Sorun: API hız limiti aşıldı.\\n"
                "Bu tur üretilemedi. Sonraki tur otomatik dener."
            )
    if job.get("no_agent"):
        if "script path resolves outside" in lower or "blocked: script path" in lower:
            return (
                "📋 Zamanlanmış görev\\n\\n"
                f"Görev: {job_name}\\n"
                "Sorun: Betik güvenli dizin dışında.\\n"
                "Ne yapmalı? Zamanlanmış görev kurulumunu yeniden çalıştırın."
            )
        if lower.startswith("script not found"):
            return (
                "📋 Zamanlanmış görev\\n\\n"
                f"Görev: {job_name}\\n"
                "Sorun: Betik dosyası bulunamadı."
            )
        if lower.startswith("script timed out"):
            return (
                "📋 Zamanlanmış görev\\n\\n"
                f"Görev: {job_name}\\n"
                "Sorun: Betik süre aşımına uğradı."
            )
        if "unable to open database file" in lower or (
            "operationalerror" in lower and "database" in lower
        ):
            return (
                "📋 Ağ\\n\\n"
                f"Görev: {job_name}\\n"
                "Sorun: Ağ cihaz veritabanı okunamıyor (dosya izni).\\n"
                "Ne yapmalı? NetAlert veritabanı erişimini düzeltin."
            )
        if "traceback" in lower:
            hint = ""
            for line in reversed(text.splitlines()):
                s = line.strip()
                if "[netalert" in s.lower() or "hata:" in s.lower():
                    hint = s[:200]
                    break
            if not hint:
                hint = "Betik hata ile çıktı (ayrıntı sunucu logunda)."
            return (
                "📋 Zamanlanmış görev\\n\\n"
                f"Görev: {job_name}\\n"
                f"Sorun: {hint}"
            )
        if "[netalert]" in lower or "netalert-devices" in lower:
            for line in reversed(text.splitlines()):
                s = line.strip()
                if "[netalert" in s.lower():
                    return (
                        "📋 Ağ\\n\\n"
                        f"Görev: {job_name}\\n"
                        f"Sorun: {s[:220]}"
                    )
    if cleaned:
        kind = "Bülten" if job.get("prompt") and not job.get("no_agent") else "Zamanlanmış görev"
        return (
            f"📋 {kind}\\n\\n"
            f"Görev: {job_name}\\n"
            f"Sorun: {cleaned[:280]}\\n"
            "Bu tur tamamlanamadı. Sonraki planlı tur otomatik dener."
        )
    return f"⚠️ Zamanlanmış görev '{job_name}' başarısız oldu: {cleaned or 'Ayrıntı yok.'}"'''


def patch_failure_summary(text: str) -> str:
    if "# pi-gateway: cron failure v7" in text:
        return text

    for start_marker in (
        "    # pi-gateway: cron failure v6",
        "    # pi-gateway: cron failure v5",
        "    # pi-gateway: cron failure v4",
        "    # pi-gateway: cron failure v3",
        "    # pi-gateway: no_agent failure v2",
        "    # pi-gateway: no_agent cron failure summary",
    ):
        if start_marker in text:
            start = text.index(start_marker)
            end = text.index(_FAILURE_END, start) + len(_FAILURE_END)
            return text[:start] + _FAILURE_V7 + text[end:]

    raise SystemExit("VERIFY_FAIL: failure block missing")


def patch_no_agent_skip_wrap(text: str) -> str:
    marker = "# pi-gateway: no_agent skip wrap"
    if marker in text:
        return text
    needle = "    if wrap_response:"
    if needle not in text:
        raise SystemExit("VERIFY_FAIL: wrap_response anchor missing")
    return text.replace(
        needle,
        "    # pi-gateway: no_agent skip wrap\n"
        "    if wrap_response and not job.get(\"no_agent\"):",
        1,
    )


def patch_failure_nudge_tr(text: str) -> str:
    marker = "pi-gateway: failure nudge tr"
    if marker in text:
        return text
    old = (
        '    return (\n'
        '        f"\\nThis job has failed {streak} runs in a row — worth a review. "\n'
        '        f"Fix its prompt/config, or pause it with `hermes cron pause {job_ref}` "\n'
        '        "(resume/remove also available) to stop the noise."\n'
        '    )'
    )
    new = (
        '    # pi-gateway: failure nudge tr\n'
        '    return (\n'
        '        f"\\n\\n—\\n"\n'
        '        f"⚠️ Bu görev üst üste {streak} kez başarısız oldu. "\n'
        '        f"Durdurmak için: hermes cron pause \\"{job_ref}\\""\n'
        '    )'
    )
    if old not in text:
        raise SystemExit("VERIFY_FAIL: nudge anchor missing")
    return text.replace(old, new, 1)


_HELPER = '''def _pi_gw_bulletin_script():
    # pi-gateway: bulletin post helper
    # pi-gateway: bulletin post helper v2
    import os as _os
    import pathlib as _pl
    cands = []
    rd = _os.environ.get("REMOTE_DIR") or ""
    if rd:
        cands.append(_pl.Path(rd) / "scripts/lib/bulletin-post.py")
    cands.append(_pl.Path.home() / "pi-gateway/scripts/lib/bulletin-post.py")
    return next((p for p in cands if p.is_file()), None)


def _pi_gw_bulletin_prepare(job, content):
    job.pop("_pi_gw_bulletin_rest", None)
    if job.get("no_agent") or not str(job.get("prompt") or "").strip():
        return content
    try:
        import json as _json
        import subprocess as _sp
        import sys as _sys
        script = _pi_gw_bulletin_script()
        if script is None:
            return content
        r = _sp.run(
            [_sys.executable, str(script), "--prepare", str(job.get("name") or ""), "--no-send"],
            input=content or "",
            capture_output=True,
            text=True,
            timeout=20,
        )
        data = _json.loads(r.stdout or "{}")
        if data.get("skip"):
            return None
        rest = data.get("rest")
        if isinstance(rest, list) and rest:
            job["_pi_gw_bulletin_rest"] = rest
        return data.get("first") or content
    except Exception:
        return content


def _pi_gw_bulletin_flush_rest(job):
    rest = job.pop("_pi_gw_bulletin_rest", None) or []
    if not rest:
        return
    try:
        import json as _json
        import subprocess as _sp
        import sys as _sys
        script = _pi_gw_bulletin_script()
        if script is None:
            return
        _sp.run(
            [_sys.executable, str(script), "--send-parts"],
            input=_json.dumps(rest, ensure_ascii=False),
            capture_output=True,
            text=True,
            timeout=30,
        )
    except Exception:
        pass


'''


def patch_bulletin_post(text: str) -> str:
    v2_marker = "# pi-gateway: bulletin post helper v2"
    v1_marker = "# pi-gateway: bulletin post helper"
    needle_fn = "def _deliver_result(job: dict, content: str) -> None:"
    if v2_marker in text:
        return text
    if v1_marker in text:
        if "def _pi_gw_bulletin_prepare(" in text and needle_fn in text:
            pre = text.split("def _pi_gw_bulletin_prepare(", 1)[0]
            post = needle_fn + text.split(needle_fn, 1)[1]
            text = pre + _HELPER + post
    else:
        if needle_fn not in text:
            return text
        text = text.replace(needle_fn, _HELPER + needle_fn, 1)
    if "# pi-gateway: bulletin post\n" not in text:
        old = (
            "        else:\n"
            "            delivery_content = content\n"
            "        # Run the async send in a fresh event loop (safe from any thread)\n"
            "        coro = _send_to_platform(platform, pconfig, chat_id, delivery_content, thread_id=thread_id)"
        )
        new = (
            "        else:\n"
            "            delivery_content = content\n"
            "        # pi-gateway: bulletin post\n"
            "        delivery_content = _pi_gw_bulletin_prepare(job, delivery_content)\n"
            "        if delivery_content is None:\n"
            "            logger.info(\"Job '%s': bulletin skeleton missing — skip delivery\", job.get(\"id\"))\n"
            "            return\n"
            "        # Run the async send in a fresh event loop (safe from any thread)\n"
            "        coro = _send_to_platform(platform, pconfig, chat_id, delivery_content, thread_id=thread_id)"
        )
        if old not in text:
            return text
        text = text.replace(old, new, 1)
    if "_pi_gw_bulletin_flush_rest(job)" not in text:
        flush_anchor = "        logger.info(\"Job '%s' delivered\""
        if flush_anchor in text:
            text = text.replace(
                flush_anchor,
                "        _pi_gw_bulletin_flush_rest(job)\n" + flush_anchor,
                1,
            )
    return text


def patch_v23_scheduler_delivery(delivery_path: pathlib.Path) -> bool:
    if not delivery_path.is_file():
        return False
    text = delivery_path.read_text()
    v2_marker = "# pi-gateway: bulletin post helper v2"
    v1_marker = "# pi-gateway: bulletin post helper"
    if v2_marker in text:
        return False
    needle_fn = "def _deliver_result(\n"
    if needle_fn not in text:
        return False
    changed = False
    if v1_marker in text and "def _pi_gw_bulletin_prepare(" in text:
        pre = text.split("def _pi_gw_bulletin_prepare(", 1)[0]
        post = needle_fn + text.split(needle_fn, 1)[1]
        text = pre + _HELPER + post
        changed = True
    else:
        old_body = (
            "    else:\n"
            "        delivery_content = content\n\n"
            "    from gateway.platforms.base import BasePlatformAdapter"
        )
        new_body = (
            "    else:\n"
            "        delivery_content = content\n"
            "    # pi-gateway: bulletin post v23\n"
            "    if not for_failure:\n"
            "        delivery_content = _pi_gw_bulletin_prepare(job, delivery_content)\n"
            "        if delivery_content is None:\n"
            "            logger.info(\"Job '%s': bulletin skeleton missing — skip delivery\", job.get(\"id\"))\n"
            "            return None\n\n"
            "    from gateway.platforms.base import BasePlatformAdapter"
        )
        if old_body not in text:
            return False
        text = text.replace(needle_fn, _HELPER + needle_fn, 1)
        text = text.replace(old_body, new_body, 1)
        changed = True
    flush_anchor = "    if suppressed_targets == len(targets):"
    if flush_anchor in text and "_pi_gw_bulletin_flush_rest(job)" not in text:
        text = text.replace(
            flush_anchor,
            "    if reached and job.get(\"_pi_gw_bulletin_rest\"):\n"
            "        _pi_gw_bulletin_flush_rest(job)\n" + flush_anchor,
            1,
        )
        changed = True
    if not changed:
        return False
    delivery_path.write_text(text)
    return True


def main() -> int:
    path = pathlib.Path(sys.argv[1])
    text = path.read_text()
    if "from cron.scheduler_delivery import" in text:
        changed = patch_v23_scheduler_delivery(path.parent / "scheduler_delivery.py")
        print("patched (v0.23+ delivery)" if changed else "v0.23+ split scheduler OK")
        return 0
    text = patch_failure_summary(text)
    text = patch_no_agent_skip_wrap(text)
    text = patch_failure_nudge_tr(text)
    text = patch_bulletin_post(text)
    path.write_text(text)
    print("patched")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
