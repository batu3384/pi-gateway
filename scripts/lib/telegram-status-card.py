#!/usr/bin/env python3
"""Sabit Telegram durum kartı — hash değişince editMessageText. GLM yok."""
from __future__ import annotations

import hashlib
import html
import importlib.util
import json
import os
import subprocess
import sys
import tempfile
import urllib.error
import urllib.parse
import urllib.request
from pathlib import Path
from types import ModuleType
from typing import Any

STATE_PATH = os.environ.get(
    "TELEGRAM_STATUS_CARD_STATE",
    "/var/lib/pi-gateway/telegram-status-card.json",
)
GATEWAY_STATE = os.environ.get("PI_GATEWAY_STATE_JSON", "/var/lib/pi-gateway/state.json")


def _run(cmd: list[str], timeout: float = 3.0) -> str:
    try:
        return subprocess.check_output(cmd, text=True, timeout=timeout, stderr=subprocess.DEVNULL).strip()
    except (subprocess.SubprocessError, OSError, ValueError):
        return ""


def _load_json(path: str) -> dict[str, Any]:
    try:
        with open(path, encoding="utf-8") as f:
            data = json.load(f)
        return data if isinstance(data, dict) else {}
    except (OSError, json.JSONDecodeError):
        return {}


def _mem_line() -> str:
    total = avail = 0
    try:
        with open("/proc/meminfo", encoding="utf-8") as f:
            for line in f:
                if line.startswith("MemTotal:"):
                    total = int(line.split()[1])
                elif line.startswith("MemAvailable:"):
                    avail = int(line.split()[1])
    except (OSError, ValueError):
        return "RAM ?"
    if total <= 0:
        return "RAM ?"
    pct = 100 * (total - avail) / total
    if pct >= 88:
        return "RAM yüksek"
    return "RAM normal"


def _disk_band(st: dict[str, Any]) -> str:
    root_pct = st.get("root_usage_pct")
    ssd_pct = st.get("ssd_usage_pct")
    warns: list[str] = []
    if isinstance(root_pct, int) and root_pct >= 80:
        warns.append(f"SD %{(root_pct // 5) * 5}+")
    if isinstance(ssd_pct, int) and ssd_pct >= 80:
        warns.append(f"SSD %{(ssd_pct // 5) * 5}+")
    return " · ".join(warns) if warns else "Alan normal"


def _latency_band(value: Any) -> str | None:
    if not isinstance(value, (int, float)) or value < 0:
        return None
    if value < 40:
        return "DNS hızlı"
    bucket = (int(value) // 50) * 50
    return f"DNS ~{max(bucket, 50)}ms"


def _docker_containers() -> set[str]:
    out = _run(["docker", "ps", "--format", "{{.Names}}"])
    return set(out.splitlines()) if out else set()


def _panels() -> ModuleType:
    path = Path(__file__).resolve().parent / "telegram-panels.py"
    spec = importlib.util.spec_from_file_location("telegram_panels", path)
    if spec is None or spec.loader is None:
        raise ImportError("telegram-panels.py yok")
    mod = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(mod)
    return mod


def build_card_text() -> str:
    st = _load_json(GATEWAY_STATE)
    health_ok = os.environ.get("PI_GATEWAY_HEALTH_OK", "1") != "0"
    running = _docker_containers()
    if running:
        dns_containers_up = "adguard" in running and "unbound" in running
    else:
        # Mac self-check veya docker CLI erişimi olmayan ortam
        dns_containers_up = health_ok and int(st.get("storage_degraded") or 0) == 0

    has_state = bool(st)
    ssd_ok = (int(st.get("ssd_mount_healthy") or 0) == 1) if has_state else True
    degraded = int(st.get("storage_degraded") or 0) == 1

    if not dns_containers_up:
        head = "🔴 DNS sorunlu"
    elif degraded or not health_ok:
        head = "🟡 DNS çalışıyor (uyarı var)"
    else:
        head = "🟢 DNS çalışıyor"

    ssd_line = "SSD kısıtlı mod" if (degraded or not ssd_ok) else "SSD sağlıklı"
    disk_line = _disk_band(st)
    mem_line = _mem_line()
    lat_line = _latency_band(st.get("dns_latency_ms"))
    perf_parts = [mem_line]
    if lat_line:
        perf_parts.append(lat_line)

    lines = [
        "<b>Durum</b>",
        html.escape(head),
        "──────────────────",
        f"• <b>Depolama:</b> {html.escape(ssd_line)} · {html.escape(disk_line)}",
        f"• <b>Performans:</b> {html.escape(' · '.join(perf_parts))}",
    ]

    cov = st.get("dns_coverage_status")
    cov_pct = st.get("dns_coverage_percent")
    if cov in ("ok", "warn", "fail") and isinstance(cov_pct, int) and cov_pct >= 0:
        cov_badge = "Tam" if cov == "ok" else f"%{(cov_pct // 10) * 10}+"
        lines.append(f"• <b>DNS Kapsam:</b> {html.escape(cov_badge)}")

    try:
        panels = _panels()
        remote_base, remote_mode = panels.remote_access_base()
        user = os.environ.get("AGH_ADMIN_USER") or os.environ.get("CADDY_AUTH_USER") or "admin"
        if remote_mode == "ts-http" and remote_base:
            lines.append(f"• <b>Erişim:</b> <code>{html.escape(remote_base)}</code> · Giriş <code>{html.escape(user)}</code>")
        elif remote_base:
            lines.append(f"• <b>Erişim:</b> <code>{html.escape(remote_base)}</code> · Giriş <code>{html.escape(user)}</code>")
        else:
            lines.append(f"• <b>Giriş:</b> <code>{html.escape(user)}</code>")
    except Exception:
        pass

    lines.append("")
    lines.append("<i>Komutlar: /menu /dns /ssd /backup /recover</i>")
    return "\n".join(lines)


def card_hash(text: str, markup: str) -> str:
    return hashlib.sha256(f"{text}\n{markup}".encode("utf-8")).hexdigest()


def _api(method: str, payload: dict[str, Any]) -> dict[str, Any]:
    del method, payload
    return {"ok": False, "description": "telegram kalkti"}


def _save_state(path: str, state: dict[str, Any]) -> None:
    Path(path).parent.mkdir(parents=True, exist_ok=True)
    tmp = f"{path}.tmp"
    with open(tmp, "w", encoding="utf-8") as f:
        json.dump(state, f, indent=2, ensure_ascii=False)
        f.write("\n")
    os.replace(tmp, path)


def apply(*, force: bool = False) -> int:
    token = os.environ.get("TELEGRAM_BOT_TOKEN") or ""
    chat = os.environ.get("TELEGRAM_CHAT_ID") or ""
    if not token or not chat:
        print("[status-card] TELEGRAM_BOT_TOKEN / TELEGRAM_CHAT_ID eksik", file=sys.stderr)
        return 1

    panels = _panels()
    markup = json.dumps(panels.inline_keyboard(panels.panel_urls(), "all"), ensure_ascii=False)
    text = build_card_text()
    digest = card_hash(text, markup)
    state = _load_json(STATE_PATH)
    msg_id = state.get("message_id")

    if not force and state.get("hash") == digest and msg_id:
        print("[status-card] hash aynı — dokunulmadı")
        return 0

    edited = False
    if msg_id:
        out = _api(
            "editMessageText",
            {
                "chat_id": chat,
                "message_id": int(msg_id),
                "parse_mode": "HTML",
                "text": text,
                "reply_markup": markup,
                "disable_web_page_preview": "true",
            },
        )
        desc = str(out.get("description") or "").lower()
        if out.get("ok") or "message is not modified" in desc:
            edited = True
        elif any(
            s in desc
            for s in (
                "message to edit not found",
                "message can't be edited",
                "message is too old",
                "message_too_old",
            )
        ):
            edited = False
        else:
            print(f"[status-card] edit: {out.get('description')}", file=sys.stderr)
            return 1

    if not edited:
        out = _api(
            "sendMessage",
            {
                "chat_id": chat,
                "parse_mode": "HTML",
                "text": text,
                "reply_markup": markup,
                "disable_web_page_preview": "true",
                "disable_notification": "true",
            },
        )
        if not out.get("ok"):
            print(f"[status-card] send: {out.get('description')}", file=sys.stderr)
            return 1
        msg_id = (out.get("result") or {}).get("message_id")
        if msg_id:
            _api(
                "pinChatMessage",
                {
                    "chat_id": chat,
                    "message_id": int(msg_id),
                    "disable_notification": "true",
                },
            )

    state["message_id"] = msg_id
    state["hash"] = digest
    _save_state(STATE_PATH, state)
    print(f"[status-card] OK message_id={msg_id}")
    return 0


def self_check() -> int:
    os.environ.setdefault("PI_GATEWAY_HEALTH_OK", "1")
    os.environ.setdefault("LAN_DOMAIN", "home")
    text = build_card_text()
    assert "<b>Durum</b>" in text, text
    assert "DNS" in text, text
    assert "DNS çalışıyor" in text or "DNS sorunlu" in text, text
    assert "RAM yüksek" in text or "RAM normal" in text or "RAM ?" in text, text
    h = card_hash(text, "{}")
    assert len(h) == 64
    old_api = globals()["_api"]
    old_token = os.environ.get("TELEGRAM_BOT_TOKEN")
    old_chat = os.environ.get("TELEGRAM_CHAT_ID")
    old_state_path = globals()["STATE_PATH"]
    calls: list[str] = []
    with tempfile.TemporaryDirectory() as td:
        state_path = str(Path(td) / "card.json")
        _save_state(state_path, {"message_id": 1, "hash": "old"})
        globals()["STATE_PATH"] = state_path
        os.environ["TELEGRAM_BOT_TOKEN"] = "test-token"
        os.environ["TELEGRAM_CHAT_ID"] = "test-chat"

        def fake_api(method: str, payload: dict[str, Any]) -> dict[str, Any]:
            calls.append(method)
            return {"ok": False, "description": "temporary Telegram failure"}

        globals()["_api"] = fake_api
        assert apply() == 1
        assert calls == ["editMessageText"], calls
    globals()["_api"] = old_api
    globals()["STATE_PATH"] = old_state_path
    if old_token is None:
        os.environ.pop("TELEGRAM_BOT_TOKEN", None)
    else:
        os.environ["TELEGRAM_BOT_TOKEN"] = old_token
    if old_chat is None:
        os.environ.pop("TELEGRAM_CHAT_ID", None)
    else:
        os.environ["TELEGRAM_CHAT_ID"] = old_chat
    print("[telegram-status-card] self-check OK")
    return 0


def main() -> int:
    mode = sys.argv[1] if len(sys.argv) > 1 else "text"
    if mode == "self-check":
        return self_check()
    if mode == "text":
        print(build_card_text())
        return 0
    if mode == "apply":
        force = "--force" in sys.argv
        return apply(force=force)
    print(f"unknown mode: {mode}", file=sys.stderr)
    return 2


if __name__ == "__main__":
    raise SystemExit(main())
