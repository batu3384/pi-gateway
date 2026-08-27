#!/usr/bin/env python3
"""AdGuard /control/stats + filtering/status → Prometheus textfile."""
from __future__ import annotations

import json
import os
import re
import sys
from datetime import datetime
from typing import Any


def parse_ts(raw: Any) -> float | None:
    if not raw or not isinstance(raw, str):
        return None
    s = raw.strip().replace("Z", "+00:00")
    s = re.sub(r"(\.\d{6})\d+", r"\1", s)
    try:
        return datetime.fromisoformat(s).timestamp()
    except ValueError:
        return None


def esc(label: str) -> str:
    return label.replace("\\", "\\\\").replace("\n", " ").replace('"', '\\"')


def _top_n() -> int:
    try:
        n = int(os.environ.get("ADGUARD_METRICS_TOP_N", "12"))
    except ValueError:
        n = 12
    return max(1, min(n, 25))


def top_pairs(raw: Any, limit: int) -> list[tuple[str, int]]:
    """AdGuard /control/stats top_* = [{name: count}, ...] or [{name, count}]."""
    if not isinstance(raw, list):
        return []
    out: list[tuple[str, int]] = []
    for item in raw:
        if not isinstance(item, dict) or not item:
            continue
        if "count" in item and ("name" in item or "ip" in item or "client" in item):
            key = str(item.get("name") or item.get("ip") or item.get("client") or "")
            try:
                out.append((key, int(item["count"])))
            except (TypeError, ValueError):
                continue
            continue
        k, v = next(iter(item.items()))
        try:
            out.append((str(k), int(v)))
        except (TypeError, ValueError):
            continue
    out.sort(key=lambda x: -x[1])
    return [(k, v) for k, v in out if k][:limit]


def render(up: int, stats: dict[str, Any], status: dict[str, Any]) -> str:
    q = int(stats.get("num_dns_queries") or 0)
    b = int(stats.get("num_blocked_filtering") or 0)
    avg = float(stats.get("avg_processing_time") or 0)
    ratio = (b / q) if q > 0 else 0.0
    sb = int(stats.get("num_replaced_safebrowsing") or 0)
    ss = int(stats.get("num_replaced_safesearch") or 0)
    par = int(stats.get("num_replaced_parental") or 0)
    lines = [
        "# HELP pi_gateway_adguard_up 1 when AdGuard API scrape succeeded",
        "# TYPE pi_gateway_adguard_up gauge",
        f"pi_gateway_adguard_up {int(up)}",
        "# HELP pi_gateway_adguard_queries DNS queries since AdGuard stats reset",
        "# TYPE pi_gateway_adguard_queries gauge",
        f"pi_gateway_adguard_queries {q}",
        "# HELP pi_gateway_adguard_blocked Queries blocked by filters since stats reset",
        "# TYPE pi_gateway_adguard_blocked gauge",
        f"pi_gateway_adguard_blocked {b}",
        "# HELP pi_gateway_adguard_blocked_ratio blocked / queries (0-1, 0 if no queries)",
        "# TYPE pi_gateway_adguard_blocked_ratio gauge",
        f"pi_gateway_adguard_blocked_ratio {ratio:.6f}",
        "# HELP pi_gateway_adguard_avg_processing_seconds AdGuard avg processing time",
        "# TYPE pi_gateway_adguard_avg_processing_seconds gauge",
        f"pi_gateway_adguard_avg_processing_seconds {avg:.6f}",
        "# HELP pi_gateway_adguard_replaced_safebrowsing Safe browsing replacements",
        "# TYPE pi_gateway_adguard_replaced_safebrowsing gauge",
        f"pi_gateway_adguard_replaced_safebrowsing {sb}",
        "# HELP pi_gateway_adguard_replaced_safesearch Safe search replacements",
        "# TYPE pi_gateway_adguard_replaced_safesearch gauge",
        f"pi_gateway_adguard_replaced_safesearch {ss}",
        "# HELP pi_gateway_adguard_replaced_parental Parental replacements",
        "# TYPE pi_gateway_adguard_replaced_parental gauge",
        f"pi_gateway_adguard_replaced_parental {par}",
    ]
    top_n = _top_n()
    lines += [
        "# HELP pi_gateway_adguard_top_client_queries Top clients (AdGuard stats window)",
        "# TYPE pi_gateway_adguard_top_client_queries gauge",
    ]
    for name, cnt in top_pairs(stats.get("top_clients"), top_n):
        lines.append(f'pi_gateway_adguard_top_client_queries{{client="{esc(name)}"}} {cnt}')
    lines += [
        "# HELP pi_gateway_adguard_top_blocked_domain Top blocked domains (stats window)",
        "# TYPE pi_gateway_adguard_top_blocked_domain gauge",
    ]
    for name, cnt in top_pairs(stats.get("top_blocked_domains"), top_n):
        lines.append(f'pi_gateway_adguard_top_blocked_domain{{domain="{esc(name)}"}} {cnt}')
    lines += [
        "# HELP pi_gateway_adguard_top_queried_domain Top queried domains (stats window)",
        "# TYPE pi_gateway_adguard_top_queried_domain gauge",
    ]
    for name, cnt in top_pairs(stats.get("top_queried_domains"), top_n):
        lines.append(f'pi_gateway_adguard_top_queried_domain{{domain="{esc(name)}"}} {cnt}')
    user_rules = status.get("user_rules") or []
    n_user = len(user_rules) if isinstance(user_rules, list) else 0
    lines += [
        "# HELP pi_gateway_adguard_user_rules AdGuard user_rules count",
        "# TYPE pi_gateway_adguard_user_rules gauge",
        f"pi_gateway_adguard_user_rules {n_user}",
        "# HELP pi_gateway_adguard_filter_rules Filter list rule count",
        "# TYPE pi_gateway_adguard_filter_rules gauge",
        "# HELP pi_gateway_adguard_filter_enabled 1 when filter list enabled",
        "# TYPE pi_gateway_adguard_filter_enabled gauge",
        "# HELP pi_gateway_adguard_filter_updated_timestamp_seconds Filter last_updated unix seconds",
        "# TYPE pi_gateway_adguard_filter_updated_timestamp_seconds gauge",
    ]
    for item in status.get("filters") or []:
        if not isinstance(item, dict):
            continue
        name = esc(str(item.get("name") or item.get("url") or "unknown"))
        rules = int(item.get("rules_count") or 0)
        enabled = 1 if item.get("enabled") else 0
        lines.append(f'pi_gateway_adguard_filter_rules{{name="{name}"}} {rules}')
        lines.append(f'pi_gateway_adguard_filter_enabled{{name="{name}"}} {enabled}')
        ts = parse_ts(item.get("last_updated") or "")
        if ts is not None:
            lines.append(
                f'pi_gateway_adguard_filter_updated_timestamp_seconds{{name="{name}"}} {int(ts)}'
            )
    return "\n".join(lines) + "\n"


def write_atomic(path: str, text: str) -> None:
    os.makedirs(os.path.dirname(path) or ".", exist_ok=True)
    tmp = path + ".tmp"
    with open(tmp, "w", encoding="utf-8") as fh:
        fh.write(text)
    os.replace(tmp, path)


def self_check() -> None:
    stats = {
        "num_dns_queries": 1000,
        "num_blocked_filtering": 250,
        "avg_processing_time": 0.012,
        "num_replaced_safebrowsing": 3,
        "top_clients": [{"192.0.2.10": 400}, {"192.0.2.20": 90}],
        "top_blocked_domains": [{"ads.example": 12}],
        "top_queried_domains": [{"google.com": 80}],
    }
    status = {
        "user_rules": ["||example.com^"],
        "filters": [
            {
                "name": "HaGeZi Pro++",
                "enabled": True,
                "rules_count": 245000,
                "last_updated": "2026-08-27T00:00:00.123456789Z",
            }
        ],
    }
    text = render(1, stats, status)
    assert "pi_gateway_adguard_blocked_ratio 0.250000" in text
    assert 'pi_gateway_adguard_filter_rules{name="HaGeZi Pro++"} 245000' in text
    assert "pi_gateway_adguard_filter_updated_timestamp_seconds" in text
    assert "pi_gateway_adguard_user_rules 1" in text
    assert 'pi_gateway_adguard_top_client_queries{client="192.0.2.10"} 400' in text
    assert 'pi_gateway_adguard_top_blocked_domain{domain="ads.example"} 12' in text
    assert "pi_gateway_adguard_replaced_safebrowsing 3" in text
    quoted = render(1, {}, {"filters": [{"name": 'a"b', "rules_count": 1, "enabled": False}]})
    assert 'name="a\\"b"' in quoted
    assert "pi_gateway_adguard_up 0" in render(0, {}, {})
    print("[adguard-metrics] self-check OK")


def main() -> int:
    if "--self-check" in sys.argv:
        self_check()
        return 0
    if len(sys.argv) < 5:
        print("usage: adguard-metrics.py OUT UP STATS_JSON_FILE STATUS_JSON_FILE", file=sys.stderr)
        return 2
    out, up_s, stats_arg, status_arg = sys.argv[1], sys.argv[2], sys.argv[3], sys.argv[4]

    def load_json(arg: str) -> dict[str, Any]:
        raw = arg
        if os.path.isfile(arg):
            with open(arg, encoding="utf-8") as fh:
                raw = fh.read()
        try:
            data = json.loads(raw) if raw.strip() else {}
        except json.JSONDecodeError:
            return {}
        return data if isinstance(data, dict) else {}

    write_atomic(out, render(int(up_s), load_json(stats_arg), load_json(status_arg)))
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
