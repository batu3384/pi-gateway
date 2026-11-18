#!/usr/bin/env python3
"""Telegram panel menu — URL builder + keyboard (CLI only).

Callers: telegram-menu.sh, hermes-menu.sh, telegram-status-card.py

Access modes:
  - Default (ENABLE_TLS=true, TS_PANEL_DIRECT_PORTS=false):
      https://<panel>.<LAN_DOMAIN> (Caddy TLS vhost; works on LAN + Tailscale DNS)
  - Direct Tailscale ports (TS_PANEL_DIRECT_PORTS=true):
      http://100.x:PORT/ (setup-tailscale-panel-ports.sh DNAT + UFW)
  - Plain LAN IP fallback (ENABLE_TLS=false):
      http://<PI_STATIC_IP>/p/...
"""
from __future__ import annotations

import html
import json
import os
import ssl
import subprocess
import sys
from typing import Any


def env_bool(name: str, default: bool = False) -> bool:
    raw = os.environ.get(name)
    if raw is None or raw == "":
        return default
    return raw.lower() in ("1", "true", "yes")


def _port(env_name: str, default: int) -> int:
    raw = (os.environ.get(env_name) or "").strip()
    try:
        return int(raw) if raw else default
    except ValueError:
        return default


def active_panels() -> list[tuple[str, str, str, str, int]]:
    """Return enabled (id, label, host, lan_path, ts_port) entries."""
    items: list[tuple[str, str, str, str, int]] = []
    if env_bool("ENABLE_CADDY", True):
        items.append(("gateway", "🏠 Ana Panel (Glance)", "gateway", "", 0))
    items.append(("dns", "🛡️ DNS (AdGuard)", "dns", "/p/dns/", _port("ADGUARD_WEB_PORT", 8080)))
    if env_bool("ENABLE_GATUS", True):
        items.append(("status", "📡 Durum (Gatus)", "status", "/p/status/", _port("GATUS_PORT", 3001)))
    if env_bool("ENABLE_MONITORING", True):
        items.append(("grafana", "📊 Grafikler", "grafana", "/p/grafana/", _port("GRAFANA_PORT", 3030)))
    if env_bool("ENABLE_NETALERTX", True):
        items.append(("devices", "🌐 Ağ Cihazları", "devices", "/p/devices/", _port("NETALERTX_PORT", 20211)))
    if env_bool("ENABLE_DOZZLE", True):
        items.append(("logs", "📜 Kayıtlar", "logs", "/p/logs/", _port("DOZZLE_PORT", 9999)))
    if env_bool("ENABLE_N8N", False):
        items.append(("n8n", "⚙️ Otomasyon", "n8n", "/p/n8n/", _port("N8N_PORT", 5678)))
    return items


def hermes_owns_inbox() -> bool:
    return env_bool("HERMES_TELEGRAM_GATEWAY", False)


def _run(cmd: list[str]) -> str:
    try:
        return subprocess.check_output(cmd, text=True, timeout=5, stderr=subprocess.DEVNULL).strip()
    except (subprocess.SubprocessError, OSError, ValueError):
        return ""


def tailscale_ip() -> str:
    ip = _run(["tailscale", "ip", "-4"]).splitlines()
    return ip[0].strip() if ip else os.environ.get("TAILSCALE_IP", "").strip()


def remote_access_base() -> tuple[str, str]:
    """Return (base_url_or_domain, mode) where mode is ts-http | home | lan | none."""
    domain = os.environ.get("LAN_DOMAIN", "home").strip() or "home"
    proto = os.environ.get("PANEL_PROTOCOL", "").strip()
    if not proto:
        proto = "https" if env_bool("ENABLE_TLS", True) else "http"

    if env_bool("TS_PANEL_DIRECT_PORTS", False):
        ts_ip = tailscale_ip()
        if ts_ip:
            return f"http://{ts_ip}", "ts-http"

    if proto == "https" or not os.environ.get("PI_STATIC_IP", "").strip():
        return f"{proto}://gateway.{domain}", "home"

    pi_ip = os.environ.get("PI_STATIC_IP", "").strip()
    if pi_ip:
        return f"http://{pi_ip}", "lan"
    return "", "none"


def panel_urls() -> list[dict[str, Any]]:
    domain = os.environ.get("LAN_DOMAIN", "home").strip() or "home"
    proto = os.environ.get("PANEL_PROTOCOL", "").strip()
    if not proto:
        proto = "https" if env_bool("ENABLE_TLS", True) else "http"
    pi_ip = os.environ.get("PI_STATIC_IP", "").strip()
    remote_base, remote_mode = remote_access_base()

    out: list[dict[str, Any]] = []
    for pid, label, host, lan_path, ts_port in active_panels():
        home_url = f"{proto}://{host}.{domain}"
        ip_url = (f"http://{pi_ip}{lan_path}" if lan_path else f"http://{pi_ip}/") if pi_ip else ""

        if remote_mode == "ts-http" and remote_base:
            remote_url = f"{remote_base}:{ts_port}/" if ts_port else f"{remote_base}/"
            button = remote_url
        elif remote_mode == "lan":
            button = ip_url or home_url
            remote_url = ip_url
        else:
            button = home_url
            remote_url = home_url

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


def _pick_url(panel: dict[str, Any], mode: str) -> str:
    if mode == "remote":
        return str(panel.get("remote") or panel.get("home") or panel.get("ip") or "")
    if mode == "home":
        return str(panel.get("home") or "")
    if mode == "ip":
        return str(panel.get("ip") or panel.get("home") or "")
    return str(panel.get("button") or "")


def inline_keyboard(panels: list[dict[str, Any]], mode: str = "all") -> dict[str, Any]:
    """Modern compact layout: hero button on row 1, 2-column grid below."""
    buttons: list[tuple[str, dict[str, str]]] = []
    for p in panels:
        url = _pick_url(p, mode)
        if not url:
            continue
        buttons.append((str(p.get("id") or ""), {"text": p["label"], "url": url}))

    rows: list[list[dict[str, str]]] = []
    if not buttons:
        return {"inline_keyboard": rows}

    start_idx = 0
    if buttons[0][0] == "gateway":
        rows.append([buttons[0][1]])
        start_idx = 1

    pair: list[dict[str, str]] = []
    for _, btn in buttons[start_idx:]:
        pair.append(btn)
        if len(pair) == 2:
            rows.append(pair)
            pair = []
    if pair:
        rows.append(pair)
    return {"inline_keyboard": rows}


def html_links(panels: list[dict[str, Any]], mode: str = "button") -> str:
    lines: list[str] = []
    for p in panels:
        url = _pick_url(p, mode)
        if not url:
            continue
        lines.append(
            f'• <a href="{html.escape(url, quote=True)}">{html.escape(p["label"])}</a>'
        )
    return "\n".join(lines)


def menu_text(panels: list[dict[str, Any]], mode: str = "all") -> str:
    remote_base, remote_mode = remote_access_base()
    user = os.environ.get("AGH_ADMIN_USER") or os.environ.get("CADDY_AUTH_USER") or "admin"
    u = html.escape(user)

    lines = [
        "<b>🖥️ Ev Sunucusu Panelleri</b>",
        f"Kullanıcı: <code>{u}</code>",
    ]
    if remote_mode == "ts-http" and remote_base:
        lines.append(f"Tailscale doğrudan: <code>{html.escape(remote_base)}</code>")
    elif remote_base:
        lines.append(f"Erişim: <code>{html.escape(remote_base)}</code>")

    if mode != "all":
        lines.append("")
        lines.append(html_links(panels, mode))

    lines.append("")
    lines.append("<i>Komutlar: /menu /dns /ssd /backup /recover</i>")
    return "\n".join(lines)


def probe_panels(timeout: float = 6.0) -> int:
    """Live HTTP check for each button URL (Pi-side)."""
    import urllib.error
    import urllib.request

    panels = panel_urls()
    bad: list[str] = []
    ok_codes = {200, 301, 302, 307, 401}
    ssl_ctx = ssl._create_unverified_context()  # noqa: S323 — local mkcert CA probe
    for p in panels:
        url = p.get("button") or ""
        if not url:
            bad.append(f"{p['id']}: empty button")
            continue
        req = urllib.request.Request(
            url, method="GET", headers={"User-Agent": "pi-gateway-panel-probe"}
        )
        try:
            ctx = ssl_ctx if url.startswith("https://") else None
            with urllib.request.urlopen(req, timeout=timeout, context=ctx) as resp:  # noqa: S310
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
    ids = {p["id"] for p in panels}
    if not env_bool("ENABLE_N8N", False) and "n8n" in ids:
        bad.append("disabled n8n exposed in panels")
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
        else:
            for key in ("button", "remote", "ip"):
                url = p.get(key) or ""
                if ":8080" in url or ":20211" in url:
                    if "/p/" not in url:
                        bad.append(f"{p['id']}.{key} raw admin port → {url}")
    kb = inline_keyboard(panels, "all")
    if not kb.get("inline_keyboard") or any(len(row) > 2 for row in kb["inline_keyboard"]):
        bad.append("invalid keyboard grid")
    if bad:
        print("FAIL:", "; ".join(bad), file=sys.stderr)
        return 1
    print(f"OK: mode={mode}; {len(panels)} active panels; compact grid")
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
        print("{}")
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
        print(match.get("button") or match.get("home") or match.get("remote") or "")
    elif mode == "hermes_owns_inbox":
        print("1" if hermes_owns_inbox() else "0")
    elif mode == "use_reply_keyboard":
        print("0")
    elif mode == "menu_webapp_url":
        print("")
    else:
        raise SystemExit(f"unknown mode: {mode}")


if __name__ == "__main__":
    main()
