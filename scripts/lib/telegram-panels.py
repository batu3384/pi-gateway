#!/usr/bin/env python3
"""Telegram panel menu — URL builder + keyboard (CLI only).

Callers: telegram-menu.sh, hermes-menu.sh, telegram-status-card.py

Remote (telefon, MagicDNS yok):
  http://100.x:PORT  — dogrudan servis (asset /p/ 404 yok)
  setup-tailscale-panel-ports.sh DNAT + UFW

LAN Wi‑Fi: http://PI_STATIC_IP/p/... (Caddy path + basic_auth)
Ev DNS: https://name.home
"""
from __future__ import annotations

import html
import json
import os
import subprocess
import sys
from typing import Any

# id, label, home host, LAN path, TS port (0 = Caddy :80 root)
PANELS: list[tuple[str, str, str, str, int]] = [
    ("gateway", "Ana", "gateway", "", 0),
    ("dns", "DNS", "dns", "/p/dns/", int(os.environ.get("ADGUARD_WEB_PORT", "8080") or "8080")),
    ("status", "Durum", "status", "/p/status/", 3001),
    ("devices", "Cihazlar", "devices", "/p/devices/", int(os.environ.get("NETALERTX_PORT", "20211") or "20211")),
    ("logs", "Kayıtlar", "logs", "/p/logs/", int(os.environ.get("DOZZLE_PORT", "9999") or "9999")),
    ("n8n", "Otomasyon", "n8n", "/p/n8n/", int(os.environ.get("N8N_PORT", "5678") or "5678")),
    ("grafana", "Grafikler", "grafana", "/p/grafana/", int(os.environ.get("GRAFANA_PORT", "3030") or "3030")),
]


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


def remote_access_base() -> tuple[str, str]:
    """(base_url without path, mode) mode: ts-http|lan|none"""
    ts_ip = tailscale_ip()
    if ts_ip:
        return f"http://{ts_ip}", "ts-http"
    pi_ip = os.environ.get("PI_STATIC_IP", "").strip()
    if pi_ip:
        return f"http://{pi_ip}", "lan"
    return "", "none"


def panel_urls() -> list[dict[str, Any]]:
    domain = os.environ.get("LAN_DOMAIN", "home")
    proto = os.environ.get("PANEL_PROTOCOL", "").strip()
    if not proto:
        proto = "https" if env_bool("ENABLE_TLS", True) else "http"
    pi_ip = os.environ.get("PI_STATIC_IP", "").strip()
    remote_base, remote_mode = remote_access_base()

    out: list[dict[str, Any]] = []
    for pid, label, host, lan_path, ts_port in PANELS:
        home_url = f"{proto}://{host}.{domain}"
        if pi_ip:
            ip_url = f"http://{pi_ip}{lan_path}" if lan_path else f"http://{pi_ip}/"
        else:
            ip_url = ""
        if remote_mode == "ts-http" and remote_base:
            if ts_port:
                remote_url = f"{remote_base}:{ts_port}/"
            else:
                remote_url = f"{remote_base}/"
            button = remote_url
        elif remote_mode == "lan":
            button = ip_url or home_url
            remote_url = ip_url
        else:
            button = home_url
            remote_url = ""
        out.append(
            {
                "id": pid,
                "label": label,
                "home": home_url,
                "ip": ip_url,
                "remote": remote_url,
                "button": button,
                "remote_mode": remote_mode,
                "ts_port": ts_port,
            }
        )
    return out


def inline_keyboard(panels: list[dict[str, Any]], mode: str = "all") -> dict[str, Any]:
    """One button per row — clearer phone taps (44pt+ effective)."""
    rows: list[list[dict[str, str]]] = []
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
        rows.append([{"text": p["label"], "url": url}])
    return {"inline_keyboard": rows}


def reply_keyboard() -> dict[str, Any]:
    """Sticky bottom button — Hermes skill `menu` catches the text."""
    return {
        "keyboard": [[{"text": "Paneller"}]],
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
        lines.append(
            f'• <a href="{html.escape(url, quote=True)}">{html.escape(p["label"])}</a>'
        )
    return "\n".join(lines)


def menu_text(panels: list[dict[str, Any]], mode: str = "all") -> str:
    """Minimal professional copy — buttons carry destinations."""
    remote_base, remote_mode = remote_access_base()
    user = os.environ.get("AGH_ADMIN_USER") or os.environ.get("CADDY_AUTH_USER") or "admin"
    u = html.escape(user)

    lines = [
        "<b>Paneller</b>",
        f"Giriş <code>{u}</code>",
    ]
    if remote_mode == "ts-http" and remote_base:
        lines.append(f"<code>{html.escape(remote_base)}</code> · uzak erişim açık")
    elif remote_mode == "lan":
        pi_ip = os.environ.get("PI_STATIC_IP", "").strip()
        if pi_ip:
            lines.append(f"Ev ağı <code>{html.escape(pi_ip)}</code>")

    if mode != "all":
        lines.append("")
        lines.append(html_links(panels, mode))

    lines.append("")
    lines.append(
        "<i>Buton → … → Safari’de Aç. Telegram içi tarayıcı kullanma. "
        "Kart: <code>/menu</code>.</i>"
    )
    return "\n".join(lines)


def probe_panels(timeout: float = 6.0) -> int:
    """Live HTTP check for each button URL (Pi-side)."""
    import urllib.error
    import urllib.request

    panels = panel_urls()
    bad: list[str] = []
    ok_codes = {200, 301, 302, 401}
    for p in panels:
        url = p.get("button") or ""
        if not url:
            bad.append(f"{p['id']}: empty button")
            continue
        req = urllib.request.Request(
            url, method="GET", headers={"User-Agent": "pi-gateway-panel-probe"}
        )
        try:
            with urllib.request.urlopen(req, timeout=timeout) as resp:  # noqa: S310
                code = int(getattr(resp, "status", 200) or 200)
        except urllib.error.HTTPError as e:
            code = int(e.code)
        except Exception as e:  # noqa: BLE001
            bad.append(f"{p['id']} {url} → {e}")
            continue
        if code not in ok_codes:
            bad.append(f"{p['id']} {url} → HTTP {code}")
            continue
        print(f"OK {p['id']} → {code} {url}")
    if bad:
        print("FAIL:", "; ".join(bad), file=sys.stderr)
        return 1
    return 0


def self_check() -> int:
    bad: list[str] = []
    panels = panel_urls()
    mode = panels[0]["remote_mode"] if panels else "none"
    for p in panels:
        btn = p.get("button") or ""
        if ".ts.net" in btn:
            bad.append(f"{p['id']} MagicDNS → {btn}")
        if mode == "ts-http":
            path = btn.split("://", 1)[-1]
            if p["id"] != "gateway" and "/p/" in path:
                bad.append(f"{p['id']} still path-proxy → {btn}")
            if p["id"] != "gateway" and p.get("ts_port") and f":{p['ts_port']}" not in btn:
                bad.append(f"{p['id']} missing TS port → {btn}")
        if mode != "ts-http":
            for key in ("button", "remote", "ip"):
                url = p.get(key) or ""
                if ":8080" in url or ":20211" in url:
                    # LAN /p/ must not expose raw admin ports
                    if "/p/" not in url:
                        bad.append(f"{p['id']}.{key} raw admin port → {url}")
    kb = inline_keyboard(panels, "all")
    if any(len(row) != 1 for row in kb["inline_keyboard"]):
        bad.append("keyboard not single-column")
    if bad:
        print("FAIL:", "; ".join(bad), file=sys.stderr)
        return 1
    print("OK: ts-http uses host:port; no MagicDNS; single-column menu")
    return 0


def main() -> None:
    mode = sys.argv[1] if len(sys.argv) > 1 else "keyboard"
    sub = sys.argv[2] if len(sys.argv) > 2 else "all"
    if mode == "self_check":
        raise SystemExit(self_check())
    if mode == "probe":
        raise SystemExit(probe_panels())
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
    elif mode == "panel_url":
        pid = sub if sub != "all" else "gateway"
        match = next((p for p in panels if p["id"] == pid), panels[0] if panels else None)
        if not match:
            raise SystemExit(f"unknown panel: {pid}")
        print(match.get("button") or match.get("remote") or match.get("home") or "")
    elif mode == "hermes_owns_inbox":
        print("1" if hermes_owns_inbox() else "0")
    elif mode == "use_reply_keyboard":
        # Always show sticky Paneller (Hermes skill `menu` handles the tap)
        print("1")
    elif mode == "menu_webapp_url":
        print("")
    else:
        raise SystemExit(f"unknown mode: {mode}")


if __name__ == "__main__":
    main()
