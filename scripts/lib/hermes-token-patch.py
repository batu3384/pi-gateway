#!/usr/bin/env python3
"""Pi Gateway — z.ai 5h kota (HTTP 429 code 1308) retry yok. Idempotent."""
from __future__ import annotations

import pathlib
import sys

MARKER = "# pi-gateway: zai 1308 no retry"

_NEEDLE = '''        if _is_openrouter_upstream_error(body, provider):
            upstream_provider = _extract_upstream_provider_name(body)
            ctx = {"upstream_provider": upstream_provider} if upstream_provider else {}
            return result_fn(
                FailoverReason.upstream_rate_limit,
                retryable=True,
                should_rotate_credential=False,
                should_fallback=True,
                error_context=ctx,
            )
        return result_fn(
            FailoverReason.rate_limit,
            retryable=True,
            should_rotate_credential=True,
            should_fallback=True,
        )'''

_REPL = '''        if _is_openrouter_upstream_error(body, provider):
            upstream_provider = _extract_upstream_provider_name(body)
            ctx = {"upstream_provider": upstream_provider} if upstream_provider else {}
            return result_fn(
                FailoverReason.upstream_rate_limit,
                retryable=True,
                should_rotate_credential=False,
                should_fallback=True,
                error_context=ctx,
            )
        # pi-gateway: zai 1308 no retry
        # 5 saatlik Coding Plan duvarı — retry tam context'i 3 kez yakar.
        if "1308" in error_msg or "usage limit reached for 5 hour" in error_msg.lower():
            return result_fn(
                FailoverReason.billing,
                retryable=False,
                should_rotate_credential=False,
                should_fallback=False,
            )
        return result_fn(
            FailoverReason.rate_limit,
            retryable=True,
            should_rotate_credential=True,
            should_fallback=True,
        )'''


_FALLBACK_TRUE = """        if "1308" in error_msg or "usage limit reached for 5 hour" in error_msg.lower():
            return result_fn(
                FailoverReason.billing,
                retryable=False,
                should_rotate_credential=False,
                should_fallback=True,
            )"""

_FALLBACK_FALSE = """        if "1308" in error_msg or "usage limit reached for 5 hour" in error_msg.lower():
            return result_fn(
                FailoverReason.billing,
                retryable=False,
                should_rotate_credential=False,
                should_fallback=False,
            )"""


def patch_classifier(text: str) -> str:
    if MARKER in text:
        if _FALLBACK_TRUE in text:
            return text.replace(_FALLBACK_TRUE, _FALLBACK_FALSE, 1)
        return text
    if _NEEDLE not in text:
        raise SystemExit("VERIFY_FAIL: 429 rate_limit return anchor missing")
    return text.replace(_NEEDLE, _REPL, 1)


def main() -> int:
    if "--self-check" in sys.argv:
        out = patch_classifier(_NEEDLE)
        assert MARKER in out
        assert _FALLBACK_FALSE in out
        assert out.count("should_fallback=True") == 2
        assert patch_classifier(out) == out
        v1 = out.replace(_FALLBACK_FALSE, _FALLBACK_TRUE, 1)
        v2 = patch_classifier(v1)
        assert _FALLBACK_FALSE in v2
        assert _FALLBACK_TRUE not in v2
        print("[hermes-token-patch] self-check OK")
        return 0
    path = pathlib.Path(sys.argv[1])
    path.write_text(patch_classifier(path.read_text()))
    print("token-patched")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
