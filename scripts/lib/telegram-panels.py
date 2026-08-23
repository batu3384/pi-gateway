#!/usr/bin/env python3
"""Telegram panel URL + inline keyboard builder (LAN / IP / Tailscale).

CLI only — not imported. Callers: scripts/pi/telegram-bot.sh, telegram-menu.sh.
"""
from __future__ import annotations

import html
import json
import os
import subprocess
import sys
from typing import Any

# host = Caddy vhost; path_remote = Tailscale/IP path prefix
PANELS: list[tuple[str, str, str, str, str]] = [
    ("gateway", "Ana Panel", "gateway", "", ""),
    ("status", "Uptime", "status", "", "/p/status"),
    ("logs", "Loglar", "logs", "", "/p/logs"),
    ("dns", "AdGuard", "dns", "", "/p/dns"),
    ("devices", "Cihazlar", "devices", "", "/p/devices"),
    ("git", "Forgejo", "git", "", "/p/git"),
    ("n8n", "n8n", "n8n", "", "/p/n8n"),
    ("sync", "Syncthing", "sync", "", "/p/sync"),
    ("grafana", "Grafana", "grafana", "", "/p/grafana"),
]

EMOJI = {
    "gateway": "🏠",
    "status": "📊",
    "logs": "📜",
    "dns": "🛡️",
    "devices": "📱",
    "git": "🐙",
    "n8n": "⚙️",
    "sync": "🔄",
    "grafana": "📈",
}


def env_bool(name: str, default: bool = False) -> bool:
    raw = os.environ.get(name)
    if raw is None or raw == "":
        return default
    return raw.lower() in ("1", "true", "yes")


def hermes_owns_inbox() -> bool:
    return env_bool("HERMES_TELEGRAM_GATEWAY", False)


def _run(cmd: list[str]) -> str:
    try:
        return subprocess.check_output(cmd, text=True, timeout=5).strip()
    except (subprocess.SubprocessError, OSError, ValueError):
        return ""


def tailscale_ip() -> str:
    ip = _run(["tailscale", "ip", "-4"]).splitlines()
    return ip[0].strip() if ip else os.environ.get("TAILSCALE_IP", "").strip()


def tailscale_dns() -> str:
    cached = os.environ.get("TAILSCALE_PANEL_URL", "").strip().rstrip("/")
    if cached.startswith("https://"):
        return cached.replace("https://", "", 1)
    if cached.startswith("http://"):
        return cached.replace("http://", "", 1)
    path = "/var/lib/pi-gateway/tailscale-panel-url"
    if os.path.isfile(path):
        raw = path_read(path)
        if raw.startswith("https://"):
            return raw.replace("https://", "", 1).rstrip("/")
    out = _run(["tailscale", "status", "--json"])
    if not out:
        return ""
    try:
        data = json.loads(out)
        return (data.get("Self", {}).get("DNSName") or "").rstrip(".")
    except json.JSONDecodeError:
        return ""


def path_read(path: str) -> str:
    try:
        with open(path, encoding="utf-8") as fh:
            return fh.read().strip()
    except OSError:
        return ""


def tailscale_serve_active() -> bool:
    out = _run(["tailscale", "serve", "status"])
    if not out or "No serve config" in out or "not enabled" in out.lower():
        return False
    return "://" in out or "proxy" in out.lower() or "443" in out


def remote_access_base() -> tuple[str, str]:
    """(base_url, mode) mode: serve|ts-http|none

    Telefon: once Tailscale IP HTTP (MagicDNS gerekmez).
    """
    ts_ip = tailscale_ip()
    if ts_ip:
        return f"http://{ts_ip}", "ts-http"
    if tailscale_serve_active():
        dns = tailscale_dns()
        if dns:
            return f"https://{dns}", "serve"
    return "", "none"


def panel_urls() -> list[dict[str, Any]]:
    domain = os.environ.get("LAN_DOMAIN", "home")
    proto = os.environ.get("PANEL_PROTOCOL", "").strip()
    if not proto:
        proto = "https" if env_bool("ENABLE_TLS", True) else "http"
    pi_ip = os.environ.get("PI_STATIC_IP", "").strip()
    remote_base, remote_mode = remote_access_base()

    out: list[dict[str, Any]] = []
    for pid, label, host, _home_suffix, remote_suffix in PANELS:
        home_url = f"{proto}://{host}.{domain}"
        ip_url = f"http://{pi_ip}{remote_suffix}" if pi_ip else ""
        remote_url = f"{remote_base}{remote_suffix}" if remote_base else ""
        if remote_mode in ("serve", "ts-http"):
            button = remote_url or ip_url or home_url
        else:
            button = ip_url or home_url
        out.append(
            {
                "id": pid,
                "label": label,
                "emoji": EMOJI.get(pid, "🔗"),
                "home": home_url,
                "ip": ip_url,
                "remote": remote_url,
                "button": button,
                "remote_mode": remote_mode,
            }
        )
    return out


def inline_keyboard(panels: list[dict[str, Any]], mode: str = "all") -> dict[str, Any]:
    """2-column URL buttons — cleaner on phone."""
    rows: list[list[dict[str, str]]] = []
    row: list[dict[str, str]] = []
    for p in panels:
        if mode == "remote":
            url = p["remote"] or p["ip"]
        elif mode == "home":
            url = p["home"]
        elif mode == "ip":
            url = p["ip"] or p.get("remote", "")
        else:
            url = p["button"]
        if not url:
            continue
        row.append({"text": f"{p['emoji']} {p['label']}", "url": url})
        if len(row) == 2:
            rows.append(row)
            row = []
    if row:
        rows.append(row)
    return {"inline_keyboard": rows}


def reply_keyboard() -> dict[str, Any]:
    """Only when panel poller owns inbox (not Hermes)."""
    return {
        "keyboard": [
            [{"text": "📋 Paneller"}],
            [{"text": "🌐 Uzaktan"}, {"text": "🏠 Ev"}],
        ],
        "resize_keyboard": True,
        "is_persistent": True,
        "one_time_keyboard": False,
    }


def html_links(panels: list[dict[str, Any]], mode: str = "button") -> str:
    lines: list[str] = []
    for p in panels:
        if mode == "remote":
            url = p["remote"] or p["ip"]
        elif mode == "home":
            url = p["home"]
        elif mode == "ip":
            url = p["ip"] or p.get("remote", "")
        else:
            url = p["button"]
        if not url:
            continue
        safe_url = html.escape(url, quote=True)
        safe_label = html.escape(p["label"])
        lines.append(f'• <a href="{safe_url}">{p["emoji"]} {safe_label}</a>')
    return "\n".join(lines)


def menu_text(panels: list[dict[str, Any]], mode: str = "all") -> str:
    """Short professional copy — buttons carry the links."""
    domain = os.environ.get("LAN_DOMAIN", "home")
    pi_ip = os.environ.get("PI_STATIC_IP", "").strip()
    remote_base, remote_mode = remote_access_base()
    ts_ip = tailscale_ip()

    user = os.environ.get("AGH_ADMIN_USER") or os.environ.get("CADDY_AUTH_USER") or "admin"
    fj = (
        os.environ.get("FORGEJO_ADMIN_USER")
        or os.environ.get("FORGEJO_LOGIN_USER")
        or "gitadmin"
    )
    u = html.escape(user)
    fju = html.escape(fj)

    lines = [
        "<b>Pi Gateway</b>",
        f"Giriş <code>{u}</code>"
        + (f" · Forgejo <code>{fju}</code>" if fju != u else "")
        + " · aynı şifre",
    ]

    if mode == "remote":
        lines.append("<b>Uzaktan</b>")
    elif mode == "home":
        lines.append(f"<b>Ev DNS</b> — *.{html.escape(domain)}")
    elif mode == "ip":
        lines.append("<b>LAN IP</b>")
    elif remote_mode == "ts-http" and ts_ip:
        lines.append(f"Uzaktan <code>http://{html.escape(ts_ip)}</code>")
    elif remote_mode == "serve" and remote_base:
        lines.append(f"Uzaktan <code>{html.escape(remote_base)}</code>")
    elif pi_ip:
        lines.append(f"LAN <code>http://{html.escape(pi_ip)}</code>")

    # Buttons only for default view — no duplicate link dump
    if mode != "all":
        lines.append("")
        lines.append(html_links(panels, mode))

    lines.append("")
    if remote_mode == "none":
        tip = "Tailscale kapalı — ev ağı / IP kullan."
    else:
        tip = "Buton → ⋯ → Safari’de Aç (Telegram içi Basic Auth yok)."
    lines.append(f"<i>{tip}</i>")
    return "\n".join(lines)


def self_check() -> int:
    """Assert: no direct AdGuard/NetAlertX ports in panel URLs."""
    bad: list[str] = []
    for p in panel_urls():
        for key in ("button", "remote", "ip", "home"):
            url = p.get(key) or ""
            if ":8080" in url or ":20211" in url:
                bad.append(f"{p['id']}.{key}={url}")
        btn = p.get("button") or ""
        if p["id"] != "gateway" and "100." in btn and "/p/" not in btn:
            bad.append(f"{p['id']}.button missing /p/ → {btn}")
    kb = inline_keyboard(panel_urls(), "all")
    for row in kb["inline_keyboard"]:
        if len(row) > 2:
            bad.append(f"keyboard row too wide: {len(row)}")
    if bad:
        print("FAIL:", "; ".join(bad), file=sys.stderr)
        return 1
    print("OK: panels avoid :8080/:20211; Tailscale buttons use /p/")
    return 0


def main() -> None:
    mode = sys.argv[1] if len(sys.argv) > 1 else "keyboard"
    sub = sys.argv[2] if len(sys.argv) > 2 else "all"

    if mode == "self_check":
        raise SystemExit(self_check())

    panels = panel_urls()

    if mode == "keyboard":
        print(json.dumps(inline_keyboard(panels, sub), ensure_ascii=False))
    elif mode == "reply_keyboard":
        print(json.dumps(reply_keyboard(), ensure_ascii=False))
    elif mode == "html":
        print(html_links(panels, sub if sub != "all" else "button"))
    elif mode == "text":
        print(menu_text(panels, sub))
    elif mode == "panels_json":
        print(json.dumps(panels, ensure_ascii=False))
    elif mode == "remote_mode":
        print(remote_access_base()[1])
    elif mode == "use_reply_keyboard":
        # Hermes owns inbox → reply keys become AI chat noise
        print("0" if hermes_owns_inbox() else "1")
    else:
        raise SystemExit(f"unknown mode: {mode}")


if __name__ == "__main__":
    main()
