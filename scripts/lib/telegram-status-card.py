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
import time
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
    used_g = (total - avail) / 1024 / 1024
    tot_g = total / 1024 / 1024
    pct = 100 * (total - avail) / total
    if pct >= 90:
        return f"RAM yüksek {used_g:.1f}/{tot_g:.1f}G"
    return f"RAM normal {used_g:.1f}/{tot_g:.1f}G"


def _docker_up(*names: str) -> bool:
    out = _run(["docker", "ps", "--format", "{{.Names}}"])
    have = set(out.splitlines()) if out else set()
    return all(n in have for n in names)


def _clock() -> str:
    return time.strftime("%H:%M")


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
    dns_up = health_ok and _docker_up("adguard", "unbound")
    if not _docker_up("adguard") and not _docker_up("unbound"):
        # docker yoksa (Mac self-check) state'e güven
        dns_up = health_ok and int(st.get("storage_degraded") or 0) == 0
    ssd_ok = int(st.get("ssd_mount_healthy") or 0) == 1
    degraded = int(st.get("storage_degraded") or 0) == 1
    dns_ms = st.get("dns_latency_ms")
    panel_ms = st.get("panel_latency_ms")

    if dns_up and not degraded:
        head = f"🟢 DNS ayakta · {_clock()}"
    else:
        head = f"🔴 DNS düştü · {_clock()}"

    ssd_line = "SSD yok — degraded" if degraded or not ssd_ok else "SSD tamam"
    parts = [ssd_line, _mem_line()]
    lat: list[str] = []
    if isinstance(dns_ms, (int, float)) and dns_ms >= 0:
        lat.append(f"DNS {int(dns_ms)}ms")
    if isinstance(panel_ms, (int, float)) and panel_ms >= 0:
        lat.append(f"Panel {int(panel_ms)}ms")
    if lat:
        parts.append(" · ".join(lat))

    lines = [
        "<b>Pi Gateway · Durum</b>",
        html.escape(head),
        html.escape(" · ".join(parts)),
    ]

    try:
        panels = _panels()
        remote_base, remote_mode = panels.remote_access_base()
        user = os.environ.get("AGH_ADMIN_USER") or os.environ.get("CADDY_AUTH_USER") or "admin"
        lines.append(f"Giriş <code>{html.escape(user)}</code>")
        if remote_mode == "ts-http" and remote_base:
            lines.append(f"<code>{html.escape(remote_base)}</code> · Tailscale açık")
        elif remote_mode == "lan":
            pi_ip = os.environ.get("PI_STATIC_IP", "").strip()
            if pi_ip:
                lines.append(f"Ev Wi‑Fi <code>{html.escape(pi_ip)}</code>")
    except Exception:
        pass

    lines.append("")
    lines.append(
        "<i>Buton → … → Safari’de Aç. Telegram içi tarayıcı kırık. "
        "Kart sabit — durum sorma.</i>"
    )
    return "\n".join(lines)


def card_hash(text: str, markup: str) -> str:
    return hashlib.sha256(f"{text}\n{markup}".encode("utf-8")).hexdigest()


def _api(method: str, payload: dict[str, Any]) -> dict[str, Any]:
    token = os.environ.get("TELEGRAM_BOT_TOKEN") or ""
    url = f"https://api.telegram.org/bot{token}/{method}"
    data = urllib.parse.urlencode(payload).encode()
    req = urllib.request.Request(url, data=data, method="POST")
    try:
        with urllib.request.urlopen(req, timeout=20) as resp:
            return json.load(resp)
    except urllib.error.HTTPError as exc:
        try:
            return json.loads(exc.read().decode("utf-8", errors="replace"))
        except Exception:
            return {"ok": False, "description": str(exc)}
    except (OSError, json.JSONDecodeError, TimeoutError) as exc:
        return {"ok": False, "description": str(exc)}


def _save_state(path: str, state: dict[str, Any]) -> None:
    Path(path).parent.mkdir(parents=True, exist_ok=True)
    tmp = f"{path}.tmp"
    with open(tmp, "w", encoding="utf-8") as f:
        json.dump(state, f, indent=2, ensure_ascii=False)
        f.write("\n")
    os.replace(tmp, path)


def apply(*, force: bool = False, once_reply_kb: bool = False) -> int:
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
        if once_reply_kb and not state.get("reply_kb"):
            _send_reply_kb(chat)
            state["reply_kb"] = 1
            _save_state(STATE_PATH, state)
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
        elif "message to edit not found" in desc or "message can't be edited" in desc:
            edited = False
        else:
            print(f"[status-card] edit: {out.get('description')}", file=sys.stderr)

    if not edited:
        out = _api(
            "sendMessage",
            {
                "chat_id": chat,
                "parse_mode": "HTML",
                "text": text,
                "reply_markup": markup,
                "disable_web_page_preview": "true",
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
    if once_reply_kb and not state.get("reply_kb"):
        _send_reply_kb(chat)
        state["reply_kb"] = 1
    _save_state(STATE_PATH, state)
    print(f"[status-card] OK message_id={msg_id}")
    return 0


def _send_reply_kb(chat: str) -> None:
    panels = _panels()
    kb = json.dumps(panels.reply_keyboard(), ensure_ascii=False)
    _api(
        "sendMessage",
        {
            "chat_id": chat,
            "parse_mode": "HTML",
            "text": "Altta <b>Paneller</b> — kartı yenile: /menu",
            "reply_markup": kb,
            "disable_web_page_preview": "true",
        },
    )


def self_check() -> int:
    os.environ.setdefault("PI_GATEWAY_HEALTH_OK", "1")
    os.environ.setdefault("LAN_DOMAIN", "home")
    text = build_card_text()
    assert "Pi Gateway · Durum" in text, text
    assert "DNS" in text, text
    h = card_hash(text, "{}")
    assert len(h) == 64
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
        once = "--once-reply-kb" in sys.argv
        return apply(force=force, once_reply_kb=once)
    print(f"unknown mode: {mode}", file=sys.stderr)
    return 2


if __name__ == "__main__":
    raise SystemExit(main())
