#!/usr/bin/env python3
"""Telegram panel URL + inline keyboard builder (LAN / IP / Tailscale)."""
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
    ("status", "Uptime Kuma", "status", "", "/p/status"),
    ("logs", "Loglar", "logs", "", "/p/logs"),
    ("dns", "AdGuard DNS", "dns", "", "/p/dns"),
    ("devices", "Cihazlar", "devices", "", "/p/devices"),
    ("git", "Forgejo", "git", "", "/p/git"),
    ("n8n", "n8n", "n8n", "", "/p/n8n"),
    ("sync", "Syncthing", "sync", "", "/p/sync"),
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
}


def env_bool(name: str, default: bool = False) -> bool:
    return os.environ.get(name, str(default)).lower() in ("1", "true", "yes")


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
        raw = Path_read(path)
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


def Path_read(path: str) -> str:
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

    Telefon icin once Tailscale IP HTTP (MagicDNS gerekmez).
    Serve HTTPS yedek — MagicDNS + Override DNS ister.
    """
    ts_ip = tailscale_ip()
    if ts_ip:
        # iPhone'da MagicDNS/DNS override sik kapali; 100.x her zaman cozulur
        return f"http://{ts_ip}", "ts-http"
    if tailscale_serve_active():
        dns = tailscale_dns()
        if dns:
            return f"https://{dns}", "serve"
    return "", "none"


def panel_urls() -> list[dict[str, Any]]:
    domain = os.environ.get("LAN_DOMAIN", "home")
    proto = os.environ.get("PANEL_PROTOCOL", "http")
    if not proto:
        proto = "https" if env_bool("ENABLE_TLS") else "http"
    pi_ip = os.environ.get("PI_STATIC_IP", "").strip()
    remote_base, remote_mode = remote_access_base()

    # Caddy /p/* only — dogrudan :8080/:20211 Tailscale UFW kapali (auth gap)
    out: list[dict[str, Any]] = []
    for pid, label, host, _home_suffix, remote_suffix in PANELS:
        home_url = f"{proto}://{host}.{domain}"
        ip_url = f"http://{pi_ip}{remote_suffix}" if pi_ip else ""
        remote_url = f"{remote_base}{remote_suffix}" if remote_base else ""
        if remote_mode == "serve":
            button = remote_url or ip_url or home_url
        elif remote_mode == "ts-http":
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
    rows: list[list[dict[str, str]]] = []
    for p in panels:
        url = ""
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
        rows.append([{"text": f"{p['emoji']} {p['label']}", "url": url}])
    return {"inline_keyboard": rows}


def reply_keyboard() -> dict[str, Any]:
    return {
        "keyboard": [
            [{"text": "📋 Tüm paneller"}],
            [{"text": "🌐 Uzaktan (Tailscale)"}, {"text": "🏠 Ev ağı"}],
            [{"text": "📍 IP yedek"}],
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
        lines.append(f"• <a href=\"{safe_url}\">{p['emoji']} {safe_label}</a>")
    return "\n".join(lines)


def menu_text(panels: list[dict[str, Any]], mode: str = "all") -> str:
    domain = os.environ.get("LAN_DOMAIN", "home")
    pi_ip = os.environ.get("PI_STATIC_IP", "").strip()
    remote_base, remote_mode = remote_access_base()
    ts_ip = tailscale_ip()

    lines = [
        "<b>Pi Gateway — Paneller</b>",
        "",
        "Butona dokun = tarayıcıda açılır.",
    ]
    if remote_mode == "serve":
        lines.append(f"<b>Uzaktan:</b> <code>{html.escape(remote_base)}</code> (Serve HTTPS)")
    elif remote_mode == "ts-http" and ts_ip:
        lines.append(
            f"<b>Uzaktan (kullan bunu):</b> <code>http://{html.escape(ts_ip)}</code>"
        )
        serve_dns = tailscale_dns()
        if serve_dns and tailscale_serve_active():
            lines.append(
                f"<i>HTTPS yedek (MagicDNS acikken): https://{html.escape(serve_dns)}</i>"
            )
        lines.append(
            "<i>iPhone: Tailscale Connected + butona bas. "
            "Telegram ici acmazsa ⋯ → Safari’de Aç.</i>"
        )
    if pi_ip:
        lines.append(f"<b>Ev LAN:</b> <code>http://{html.escape(pi_ip)}/p/…</code>")
    lines.append(f"<b>Ev DNS:</b> *.{domain} (Pi DNS gerekli)")
    lines.append("")
    if mode == "remote":
        lines.append("<b>Uzaktan (Tailscale)</b>")
    elif mode == "home":
        lines.append("<b>Ev ağı (*.home)</b>")
    elif mode == "ip":
        lines.append("<b>IP yedek</b>")
    else:
        lines.append("<b>Linkler</b>")
    lines.append(html_links(panels, mode if mode != "all" else "button"))
    lines.append("")
    lines.append(
        "<i>⚠️ Telegram içi tarayıcıda Basic Auth çalışmaz. "
        "Butona bas → ⋯ → Safari’de Aç. Tailscale açık olsun. "
        "Eski https://…tailnet linkleri işe yaramaz (Serve kapalı).</i>"
    )
    return "\n".join(lines)


def main() -> None:
    mode = sys.argv[1] if len(sys.argv) > 1 else "keyboard"
    sub = sys.argv[2] if len(sys.argv) > 2 else "all"
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
    else:
        raise SystemExit(f"unknown mode: {mode}")


if __name__ == "__main__":
    main()
