#!/usr/bin/env python3
"""Pi Gateway — Hermes scheduler.py yamalari (idempotent)."""
from __future__ import annotations

import pathlib
import sys

_FAILURE_END = '    return f"⚠️ Cron \'{job_name}\' failed: {cleaned}"'

_FAILURE_V6 = '''    # pi-gateway: cron failure v6
    if not job.get("no_agent"):
        if "timed out after" in lower or "non-streaming api" in lower or (
            "stale" in lower and "timeout" in lower
        ):
            return (
                "📋 Pi Gateway · Bülten\\n\\n"
                f"Görev: {job_name}\\n"
                "Sorun: Model yanıtı zaman aşımı.\\n"
                "Bülten bu tur üretilemedi. Sonraki planlı tur otomatik dener.\\n"
                "Piyasa 18:55 ayrı kanaldan gider."
            )
        if "firecrawl" in lower and ("403" in lower or "forbidden" in lower):
            return (
                "📋 Pi Gateway · Bülten\\n\\n"
                f"Görev: {job_name}\\n"
                "Sorun: Web arama (Firecrawl 403).\\n"
                "Bülten bu tur üretilemedi. Sonraki tur otomatik dener.\\n"
                "Çözüm: patch-hermes-config-pi.sh — web.search_backend=ddgs."
            )
        if (
            "http 400" in lower
            or "potentially unsafe" in lower
            or "sensitive content" in lower
        ):
            return (
                "📋 Pi Gateway · Bülten\\n\\n"
                f"Görev: {job_name}\\n"
                "Sorun: Model sağlayıcı güvenlik filtresi (HTTP 400).\\n"
                "Bülten bu tur üretilemedi. Sonraki planlı tur otomatik dener.\\n"
                "Piyasa 18:55 ayrı kanaldan gider."
            )
        if "http 429" in lower or "rate limit" in lower:
            return (
                "📋 Pi Gateway · Bülten\\n\\n"
                f"Görev: {job_name}\\n"
                "Sorun: API hız limiti (HTTP 429).\\n"
                "Bülten bu tur üretilemedi. Sonraki tur otomatik dener."
            )
    if job.get("no_agent"):
        if "script path resolves outside" in lower or "blocked: script path" in lower:
            return (
                "📋 Pi Gateway · Zamanlanmış görev\\n\\n"
                f"Görev: {job_name}\\n"
                "Sorun: Betik güvenlik dizini dışında (~/.hermes/scripts gerekli).\\n"
                "Çözüm: setup-hermes-cron-scripts.sh + setup-hermes-cron.sh"
            )
        if lower.startswith("script not found"):
            return (
                "📋 Pi Gateway · Zamanlanmış görev\\n\\n"
                f"Görev: {job_name}\\n"
                "Sorun: Betik dosyası bulunamadı."
            )
        if lower.startswith("script timed out"):
            return (
                "📋 Pi Gateway · Zamanlanmış görev\\n\\n"
                f"Görev: {job_name}\\n"
                "Sorun: Betik süre aşımına uğradı."
            )
        if "unable to open database file" in lower or (
            "operationalerror" in lower and "database" in lower
        ):
            return (
                "📋 Pi Gateway · Ağ Gözcüsü\\n\\n"
                f"Görev: {job_name}\\n"
                "Sorun: NetAlertX veritabanı okunamıyor (dosya izni).\\n"
                "Çözüm: bash scripts/pi/ensure-netalert-db-access.sh"
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
                "📋 Pi Gateway · Zamanlanmış görev\\n\\n"
                f"Görev: {job_name}\\n"
                f"Sorun: {hint}"
            )
        if "[netalert]" in lower or "netalert-devices" in lower:
            for line in reversed(text.splitlines()):
                s = line.strip()
                if "[netalert" in s.lower():
                    return (
                        "📋 Pi Gateway · Ağ Gözcüsü\\n\\n"
                        f"Görev: {job_name}\\n"
                        f"Sorun: {s[:220]}"
                    )
    if cleaned:
        kind = "Bülten" if job.get("prompt") and not job.get("no_agent") else "Zamanlanmış görev"
        return (
            f"📋 Pi Gateway · {kind}\\n\\n"
            f"Görev: {job_name}\\n"
            f"Sorun: {cleaned[:280]}\\n"
            "Bu tur tamamlanamadı. Sonraki planlı tur otomatik dener."
        )
    return f"⚠️ Cron '{job_name}' failed: {cleaned}"'''


def patch_failure_summary(text: str) -> str:
    marker_v6 = "# pi-gateway: cron failure v6"
    if marker_v6 in text:
        return text

    for start_marker in (
        "    # pi-gateway: cron failure v5",
        "    # pi-gateway: cron failure v4",
        "    # pi-gateway: cron failure v3",
        "    # pi-gateway: no_agent failure v2",
        "    # pi-gateway: no_agent cron failure summary",
    ):
        if start_marker in text:
            start = text.index(start_marker)
            end = text.index(_FAILURE_END, start) + len(_FAILURE_END)
            return text[:start] + _FAILURE_V6 + text[end:]

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


def main() -> int:
    path = pathlib.Path(sys.argv[1])
    text = path.read_text()
    text = patch_failure_summary(text)
    text = patch_no_agent_skip_wrap(text)
    text = patch_failure_nudge_tr(text)
    path.write_text(text)
    print("patched")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
