#!/usr/bin/env python3
"""Pi Gateway — Hermes gateway/run.py yamalari (idempotent)."""
from __future__ import annotations

import pathlib
import sys

_SHUTDOWN_V2 = '''        # pi-gateway: shutdown msg tr v2
        if self._restart_requested:
            hint = (
                "Devam eden görev kesilecek. "
                "Yeniden açılınca bir mesaj gönder."
            )
            msg = f"⚠️ Gateway yeniden başlatılıyor — {hint}"
        else:
            msg = (
                "⚠️ Gateway kısa süre kapanıyor (güncelleme). "
                "Devam eden görev varsa kesilir."
            )'''

_SHUTDOWN_V1 = '''        # pi-gateway: shutdown msg tr
        if self._restart_requested:
            hint = (
                "Devam eden görev kesilecek. "
                "Yeniden başladıktan sonra mesaj gönder."
            )
            msg = f"⚠️ Gateway yeniden başlatılıyor — {hint}"
        else:
            msg = "⚠️ Gateway kapatılıyor — kısa kesinti (cron/deploy). Devam eden AI görevi varsa kesilir."'''

_SHUTDOWN_UPSTREAM = '''        hint = (
            "Your current task will be interrupted. "
            "Send any message after restart and I'll try to resume where you left off."
            if self._restart_requested
            else "Your current task will be interrupted."
        )
        msg = f"⚠️ Gateway {action} — {hint}"'''


def patch_shutdown_message(text: str) -> str:
    if "# pi-gateway: shutdown msg tr v2" in text:
        return text
    if _SHUTDOWN_V1 in text:
        return text.replace(_SHUTDOWN_V1, _SHUTDOWN_V2, 1)
    if _SHUTDOWN_UPSTREAM not in text:
        raise SystemExit("VERIFY_FAIL: shutdown hint anchor missing")
    return text.replace(_SHUTDOWN_UPSTREAM, _SHUTDOWN_V2, 1)


def main() -> int:
    path = pathlib.Path(sys.argv[1])
    text = patch_shutdown_message(path.read_text())
    path.write_text(text)
    print("gateway patched")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
