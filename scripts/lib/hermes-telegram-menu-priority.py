#!/usr/bin/env python3
"""Ensure Telegram BotCommand menu prioritizes Pi Gateway skills (/menu, /dns, /ssd, /backup, /recover).

Hermes caps visible commands (~60); skill commands fill leftover slots and often
drop. platforms.telegram.extra.command_menu.priority prepends survivors.

Exit 0 if config changed, 1 if already correct / unavailable.
"""
from __future__ import annotations

import pathlib
import sys

try:
    import yaml
except ImportError:
    raise SystemExit(1)

WANT = ["menu", "dns", "ssd", "backup", "recover", "status", "new", "help", "commands"]
DROP = {"paneller", "pi-gateway-menu"}
CFG = pathlib.Path.home() / ".hermes" / "config.yaml"
if not CFG.is_file():
    raise SystemExit(1)

data = yaml.safe_load(CFG.read_text()) or {}
if not isinstance(data, dict):
    raise SystemExit(1)

platforms = data.setdefault("platforms", {})
if not isinstance(platforms, dict):
    raise SystemExit(1)
telegram = platforms.setdefault("telegram", {})
if not isinstance(telegram, dict):
    raise SystemExit(1)
extra = telegram.setdefault("extra", {})
if not isinstance(extra, dict):
    raise SystemExit(1)
menu = extra.setdefault("command_menu", {})
if not isinstance(menu, dict):
    raise SystemExit(1)

cur = menu.get("priority")
if not isinstance(cur, list):
    cur = []
cur_norm = [str(x).strip() for x in cur if str(x).strip() and str(x).strip() not in DROP]

merged: list[str] = []
seen: set[str] = set()
for name in WANT + cur_norm:
    if name not in seen:
        seen.add(name)
        merged.append(name)

changed = False
if menu.get("priority_mode", "prepend") != "prepend":
    menu["priority_mode"] = "prepend"
    changed = True
if menu.get("priority") != merged:
    menu["priority"] = merged
    changed = True
if int(menu.get("max_commands") or 0) < 60:
    menu["max_commands"] = 60
    changed = True

if not changed:
    raise SystemExit(1)

CFG.write_text(yaml.safe_dump(data, sort_keys=False, allow_unicode=True, default_flow_style=False))
raise SystemExit(0)
