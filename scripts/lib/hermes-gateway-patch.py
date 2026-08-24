#!/usr/bin/env python3
"""Pi Gateway — Hermes gateway/run.py yamalari (idempotent)."""
from __future__ import annotations

import pathlib
import sys


def patch_shutdown_message(text: str) -> str:
    marker = "# pi-gateway: shutdown msg tr"
    if marker in text:
        return text
    old = '''        hint = (
            "Your current task will be interrupted. "
            "Send any message after restart and I'll try to resume where you left off."
            if self._restart_requested
            else "Your current task will be interrupted."
        )
        msg = f"⚠️ Gateway {action} — {hint}"'''
    if old not in text:
        raise SystemExit("VERIFY_FAIL: shutdown hint anchor missing")
    new = '''        # pi-gateway: shutdown msg tr
        if self._restart_requested:
            hint = (
                "Devam eden görev kesilecek. "
                "Yeniden başladıktan sonra mesaj gönder."
            )
            msg = f"⚠️ Pi Gateway yeniden başlatılıyor — {hint}"
        else:
            msg = "⚠️ Pi Gateway kapatılıyor — kısa kesinti (cron/deploy). Devam eden AI görevi varsa kesilir."'''
    return text.replace(old, new, 1)


def main() -> int:
    path = pathlib.Path(sys.argv[1])
    text = patch_shutdown_message(path.read_text())
    path.write_text(text)
    print("gateway patched")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
