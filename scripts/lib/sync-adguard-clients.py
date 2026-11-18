#!/usr/bin/env python3
"""Sync named ZTE modem LAN devices and Pi Gateway self-client to AdGuard Home."""
from __future__ import annotations

import http.cookiejar
import ipaddress
import json
import os
import re
import subprocess
import sys
import urllib.error
import urllib.request
from pathlib import Path
from typing import Any

LIB_DIR = Path(__file__).resolve().parent
if str(LIB_DIR) not in sys.path:
    sys.path.insert(0, str(LIB_DIR))

from modem_inventory import _normalise_mac, _usable_name, load_modem_inventory  # noqa: E402

SKIP_NAMES = frozenset(
    {
        "router (zte)",
        "gizlilik mac (iphone/android/mac)",
        "gizlilik mac",
    }
)
_LEGACY_SUFFIX_RE = re.compile(r"-\d{1,3}$")


def usable_client_name(name: Any) -> str:
    clean = _usable_name(name)
    if not clean or clean.lower() in SKIP_NAMES:
        return ""
    return clean


def _strip_zone(ip_str: str) -> str:
    return str(ip_str or "").strip().split("%", 1)[0]


def _is_plain_ip(value: str) -> bool:
    raw = _strip_zone(value)
    if not raw or "/" in raw:
        return False
    try:
        ipaddress.ip_address(raw)
        return True
    except ValueError:
        return False


def _normalise_plain_ip(value: str) -> str:
    raw = _strip_zone(value)
    if not raw or "/" in raw:
        return ""
    try:
        return str(ipaddress.ip_address(raw))
    except ValueError:
        return ""


def read_local_pi_macs(ifaces: tuple[str, ...] = ("eth0", "wlan0")) -> list[str]:
    """Read local NIC MAC addresses from sysfs when available."""
    macs: list[str] = []
    seen: set[str] = set()
    for iface in ifaces:
        path = Path(f"/sys/class/net/{iface}/address")
        try:
            raw = path.read_text(encoding="utf-8").strip()
        except OSError:
            continue
        mac = _normalise_mac(raw)
        if mac and mac != "00:00:00:00:00:00" and mac not in seen:
            seen.add(mac)
            macs.append(mac)
    return macs


def build_pi_gateway_spec(pi_ip: str, pi_ula: str, pi_macs: list[str]) -> dict[str, Any]:
    """Build the Pi Gateway self-client spec with querylog/stats ignored."""
    candidates: list[str] = ["127.0.0.1", "::1", "172.16.0.0/12"]
    v4 = _normalise_plain_ip(pi_ip)
    if v4:
        candidates.append(v4)
    ula_raw = str(pi_ula or "").strip().split("/", 1)[0]
    v6 = _normalise_plain_ip(ula_raw)
    if v6:
        candidates.append(v6)
    for raw_mac in pi_macs:
        mac = _normalise_mac(raw_mac)
        if mac:
            candidates.append(mac)

    ids: list[str] = []
    seen: set[str] = set()
    for item in candidates:
        key = item.lower()
        if key not in seen:
            seen.add(key)
            ids.append(item)
    return {
        "name": "Pi Gateway",
        "ids": ids,
        "ignore_querylog": True,
        "ignore_statistics": True,
    }


def load_client_aliases(path: str) -> dict[str, str]:
    """Load local MAC/IP -> friendly name map from untracked JSON file."""
    if not path:
        return {}
    try:
        data = json.loads(Path(path).read_text(encoding="utf-8"))
    except (OSError, json.JSONDecodeError, TypeError):
        return {}
    if not isinstance(data, dict):
        return {}
    out: dict[str, str] = {}
    for k, v in data.items():
        key = _normalise_mac(k) or _normalise_plain_ip(str(k))
        name = usable_client_name(v)
        if key and name:
            out[key.lower()] = name
    return out


def load_neigh_ips(iface: str = "eth0") -> tuple[dict[str, str], dict[str, list[str]]]:
    """Read kernel ARP/NDP neighbors to correlate active MACs with IPv4 and IPv6."""
    ipv4_by_mac: dict[str, str] = {}
    ipv6_ranked: dict[str, list[tuple[int, str]]] = {}
    try:
        out = subprocess.check_output(
            ["ip", "neigh", "show", "dev", iface],
            text=True,
            timeout=5,
            stderr=subprocess.DEVNULL,
        )
    except (OSError, subprocess.SubprocessError):
        return {}, {}

    priority = {"REACHABLE": 0, "DELAY": 1, "STALE": 2, "PROBE": 3}
    for line in out.splitlines():
        parts = line.split()
        if len(parts) < 3 or "lladdr" not in parts:
            continue
        state = parts[-1].upper()
        if state in ("FAILED", "INCOMPLETE"):
            continue
        rank = priority.get(state, 4)
        ip_norm = _normalise_plain_ip(parts[0])
        if not ip_norm:
            continue
        idx = parts.index("lladdr") + 1
        if idx >= len(parts):
            continue
        mac = _normalise_mac(parts[idx])
        if not mac:
            continue
        addr = ipaddress.ip_address(ip_norm)
        if addr.version == 4:
            ipv4_by_mac.setdefault(mac, ip_norm)
        elif addr.version == 6 and not addr.is_multicast:
            ipv6_ranked.setdefault(mac, []).append((rank, ip_norm))

    ipv6s_by_mac: dict[str, list[str]] = {}
    for mac, items in ipv6_ranked.items():
        items.sort(key=lambda pair: (pair[0], pair[1].startswith("fe80:")))
        uniq: list[str] = []
        seen6: set[str] = set()
        for _, ip6 in items:
            if ip6 not in seen6:
                seen6.add(ip6)
                uniq.append(ip6)
            if len(uniq) >= 6:
                break
        ipv6s_by_mac[mac] = uniq
    return ipv4_by_mac, ipv6s_by_mac


def build_desired_clients(
    inventory: dict[str, Any],
    *,
    pi_spec: dict[str, Any] | None = None,
    aliases: dict[str, str] | None = None,
    neigh_v4: dict[str, str] | None = None,
    neigh_v6: dict[str, list[str]] | None = None,
) -> list[dict[str, Any]]:
    """Return deduplicated persistent AdGuard client specs."""
    devices = inventory.get("devices") or []
    fresh = bool(inventory.get("fresh"))
    alias_map = aliases or {}
    nv4 = neigh_v4 or {}
    nv6 = neigh_v6 or {}

    raw_entries: list[tuple[str, list[str], bool]] = []
    seen_ids: set[str] = set()
    pi_owned: set[str] = set()

    if pi_spec and pi_spec.get("ids"):
        for cid in pi_spec["ids"]:
            low = str(cid).strip().lower()
            if low:
                pi_owned.add(low)
                seen_ids.add(low)

    for dev in devices:
        if not isinstance(dev, dict) or dev.get("active") is False:
            continue
        mac = _normalise_mac(dev.get("mac"))
        ip = _normalise_plain_ip(str(dev.get("ip") or ""))
        if not ip and mac and mac in nv4:
            ip = nv4[mac]
        if (mac and mac in pi_owned) or (ip and ip.lower() in pi_owned):
            continue

        name = usable_client_name(dev.get("name") or dev.get("label"))
        if not name:
            name = alias_map.get(mac, "") or (alias_map.get(ip.lower(), "") if ip else "")
        if not name:
            continue

        ids: list[str] = []
        if mac:
            ids.append(mac)
        if ip and (fresh or mac):
            ids.append(ip)
        if mac and mac in nv6:
            ids.extend(nv6[mac])

        deduped: list[str] = []
        for item in ids:
            key = item.lower()
            if key not in seen_ids and key not in pi_owned:
                seen_ids.add(key)
                deduped.append(item)
        if not deduped:
            continue
        raw_entries.append((name, deduped, False))

    name_counts: dict[str, int] = {}
    for name, _, _ in raw_entries:
        name_counts[name.lower()] = name_counts.get(name.lower(), 0) + 1

    desired: list[dict[str, Any]] = []
    used_names: set[str] = set()
    if pi_spec and pi_spec.get("ids"):
        used_names.add(str(pi_spec["name"]).lower())
        desired.append(dict(pi_spec))

    for name, ids, _ in raw_entries:
        final_name = name
        if name_counts[name.lower()] > 1:
            suffix = next((i.split(".")[-1] for i in ids if "." in i), "")
            candidate = f"{name}-{suffix}" if suffix else name
            if candidate.lower() not in used_names:
                final_name = candidate
        if final_name.lower() in used_names:
            continue
        used_names.add(final_name.lower())
        desired.append({"name": final_name, "ids": ids})
    return desired


def plan_sync(
    existing_clients: list[dict[str, Any]],
    desired_clients: list[dict[str, Any]],
    *,
    fresh: bool = True,
) -> tuple[list[str], list[dict[str, Any]], list[tuple[str, dict[str, Any]]]]:
    """Compute non-destructive AdGuard client delete/add/update payloads."""
    existing_by_name: dict[str, dict[str, Any]] = {}
    owner_by_id: dict[str, str] = {}
    for c in existing_clients:
        if not isinstance(c, dict):
            continue
        cname = str(c.get("name") or "").strip()
        if not cname:
            continue
        existing_by_name[cname.lower()] = c
        for cid in c.get("ids") or []:
            key = str(cid).strip().lower()
            if key:
                owner_by_id[key] = cname.lower()

    to_delete: list[str] = []
    pi_target = next((s for s in desired_clients if str(s.get("name", "")).lower() == "pi gateway"), None)
    if pi_target is not None:
        pi_ids = {str(x).strip().lower() for x in (pi_target.get("ids") or []) if str(x).strip()}
        for key, c in list(existing_by_name.items()):
            if key == "pi gateway":
                continue
            cur_set = {str(x).strip().lower() for x in (c.get("ids") or []) if str(x).strip()}
            if cur_set and cur_set <= pi_ids:
                to_delete.append(str(c["name"]))
                existing_by_name.pop(key, None)
                for cid_low in cur_set:
                    if owner_by_id.get(cid_low) == key:
                        owner_by_id.pop(cid_low, None)

    def find_match(name: str, target_ids: list[str]) -> dict[str, Any] | None:
        match = existing_by_name.get(name.lower())
        if match is not None:
            return match
        ordered = [c for c in target_ids if not _is_plain_ip(c)] + [
            c for c in target_ids if _is_plain_ip(c)
        ]
        for cid in ordered:
            owner = owner_by_id.get(cid.lower())
            if owner and owner in existing_by_name:
                return existing_by_name[owner]
        return None

    matched_specs: list[tuple[dict[str, Any], dict[str, Any] | None, set[str]]] = []
    for spec in desired_clients:
        target_ids = spec["ids"]
        match = find_match(spec["name"], target_ids)
        target_ips = {c.lower() for c in target_ids if _is_plain_ip(c)}
        has_mac = any(":" in c and "/" not in c and _normalise_mac(c) for c in target_ids)
        if (fresh or spec.get("name", "").lower() == "pi gateway") and match is not None and (
            has_mac or spec.get("name", "").lower() == "pi gateway"
        ):
            match_key = str(match["name"]).lower()
            for raw_id in match.get("ids") or []:
                cid = str(raw_id).strip()
                if _is_plain_ip(cid) and cid.lower() not in target_ips:
                    if owner_by_id.get(cid.lower()) == match_key:
                        owner_by_id.pop(cid.lower(), None)
        matched_specs.append((spec, match, target_ips))

    to_add: list[dict[str, Any]] = []
    to_update: list[tuple[str, dict[str, Any]]] = []

    for spec, match, target_ips in matched_specs:
        name = spec["name"]
        target_ids = spec["ids"]
        is_pi = name.lower() == "pi gateway"

        if match is not None:
            old_name = str(match["name"])
            match_key = old_name.lower()
            free_ids = [
                cid
                for cid in target_ids
                if owner_by_id.get(cid.lower(), match_key) == match_key
            ]
            cur_ids = [str(x).strip() for x in (match.get("ids") or []) if str(x).strip()]
            has_mac = any(":" in c and "/" not in c and _normalise_mac(c) for c in target_ids)
            if is_pi:
                merged_ids = [
                    x for x in cur_ids if x.lower() in {t.lower() for t in target_ids} or "/" in x
                ]
            elif fresh and has_mac:
                merged_ids = [
                    x for x in cur_ids if not (_is_plain_ip(x) and x.lower() not in target_ips)
                ]
            else:
                merged_ids = list(cur_ids)
            for cid in free_ids:
                if cid.lower() not in {x.lower() for x in merged_ids}:
                    merged_ids.append(cid)

            new_name = old_name
            if old_name.lower() != name.lower() and _LEGACY_SUFFIX_RE.search(old_name):
                if name.lower() not in existing_by_name:
                    new_name = name

            updated = dict(match)
            changed = merged_ids != cur_ids or new_name != old_name
            if is_pi:
                if updated.get("ignore_querylog") is not True or updated.get("ignore_statistics") is not True:
                    changed = True
                updated["ignore_querylog"] = True
                updated["ignore_statistics"] = True

            if changed:
                updated["name"] = new_name
                updated["ids"] = merged_ids
                if new_name.lower() != old_name.lower():
                    existing_by_name.pop(match_key, None)
                    existing_by_name[new_name.lower()] = updated
                    match_key = new_name.lower()
                to_update.append((old_name, updated))
                for cid in merged_ids:
                    owner_by_id[cid.lower()] = match_key
        else:
            free_ids = [cid for cid in target_ids if cid.lower() not in owner_by_id]
            if not free_ids:
                continue
            payload: dict[str, Any] = {
                "name": name,
                "ids": free_ids,
                "use_global_settings": True,
                "filtering_enabled": True,
                "parental_enabled": False,
                "safebrowsing_enabled": False,
                "use_global_blocked_services": True,
                "ignore_querylog": bool(spec.get("ignore_querylog", False)),
                "ignore_statistics": bool(spec.get("ignore_statistics", False)),
            }
            to_add.append(payload)
            existing_by_name[name.lower()] = payload
            for cid in free_ids:
                owner_by_id[cid.lower()] = name.lower()

    if len(to_update) > 1:
        orig_by_name = {
            str(c.get("name") or "").strip(): {str(x).strip().lower() for x in (c.get("ids") or [])}
            for c in existing_clients
            if isinstance(c, dict) and str(c.get("name") or "").strip()
        }
        held_now = {old_name: orig_by_name.get(old_name, set()) for old_name, _ in to_update}
        ordered_updates: list[tuple[str, dict[str, Any]]] = []
        remaining = list(to_update)
        while remaining:
            progressed = False
            for idx, (o_name, upd) in enumerate(remaining):
                want = {str(x).strip().lower() for x in (upd.get("ids") or [])}
                conflict = any(
                    other_name != o_name and (want & other_ids)
                    for other_name, other_ids in held_now.items()
                )
                if not conflict:
                    ordered_updates.append((o_name, upd))
                    held_now[o_name] = want
                    remaining.pop(idx)
                    progressed = True
                    break
            if not progressed:
                ordered_updates.extend(remaining)
                break
        to_update = ordered_updates

    return to_delete, to_add, to_update


class AghClient:
    def __init__(self, base: str, user: str, password: str, timeout: float = 8.0) -> None:
        self.base = base.rstrip("/")
        self.timeout = timeout
        jar = http.cookiejar.CookieJar()
        self.opener = urllib.request.build_opener(
            urllib.request.ProxyHandler({}),
            urllib.request.HTTPCookieProcessor(jar),
        )
        self._login(user, password)

    def _request(
        self, method: str, path: str, body: Any = None, *, expect_json: bool = True
    ) -> Any:
        data = None if body is None else json.dumps(body, ensure_ascii=False).encode("utf-8")
        headers = {"Content-Type": "application/json"} if data is not None else {}
        req = urllib.request.Request(f"{self.base}{path}", data=data, headers=headers, method=method)
        with self.opener.open(req, timeout=self.timeout) as resp:
            raw = resp.read()
        if not expect_json or not raw:
            return None
        return json.loads(raw.decode("utf-8"))

    def _login(self, user: str, password: str) -> None:
        self._request(
            "POST",
            "/control/login",
            {"name": user, "password": password},
            expect_json=False,
        )

    def get_clients(self) -> list[dict[str, Any]]:
        data = self._request("GET", "/control/clients", expect_json=True)
        if isinstance(data, dict) and isinstance(data.get("clients"), list):
            return data["clients"]
        return []

    def add_client(self, payload: dict[str, Any]) -> None:
        self._request("POST", "/control/clients/add", payload, expect_json=False)

    def update_client(self, old_name: str, data: dict[str, Any]) -> None:
        self._request(
            "POST",
            "/control/clients/update",
            {"name": old_name, "data": data},
            expect_json=False,
        )

    def delete_client(self, name: str) -> None:
        self._request("POST", "/control/clients/delete", {"name": name}, expect_json=False)


def self_check() -> None:
    pi_spec = build_pi_gateway_spec("192.0.2.10", "fd00:7069:6777::53/64", ["00:53:00:00:00:01", "00:53:00:00:00:02"])
    aliases = {"02:00:53:00:00:09": "Workstation-Mini"}
    nv6 = {"02:00:53:00:00:09": ["2001:db8::9", "fe80::53:9"]}
    inv = {
        "fresh": True,
        "devices": [
            {"name": "pi-host", "ip": "192.0.2.10", "mac": "00:53:00:00:00:01", "privacy_mac": False},
            {"name": "pi-host", "mac": "00:53:00:00:00:02", "privacy_mac": False},
            {"name": "Phone", "ip": "192.0.2.28", "mac": "02:00:53:00:00:28", "privacy_mac": True},
            {"name": "", "ip": "192.0.2.19", "mac": "02:00:53:00:00:09", "privacy_mac": True},
            {"name": "Gizlilik MAC (iPhone/Android/Mac)", "ip": "192.0.2.20", "mac": "02:aa:bb:cc:dd:02", "privacy_mac": True},
            {"name": "Router (ZTE)", "ip": "192.0.2.1", "mac": "aa:bb:cc:dd:ee:99", "privacy_mac": False},
        ],
    }
    desired = build_desired_clients(inv, pi_spec=pi_spec, aliases=aliases, neigh_v6=nv6)
    by_name = {d["name"]: d for d in desired}
    assert set(by_name) == {"Pi Gateway", "Phone", "Workstation-Mini"}, by_name
    assert by_name["Pi Gateway"]["ignore_querylog"] is True
    assert by_name["Pi Gateway"]["ignore_statistics"] is True
    assert "fd00:7069:6777::53" in by_name["Pi Gateway"]["ids"]
    assert by_name["Workstation-Mini"]["ids"] == [
        "02:00:53:00:00:09",
        "192.0.2.19",
        "2001:db8::9",
        "fe80::53:9",
    ]

    existing = [
        {"name": "pi-host", "ids": ["00:53:00:00:00:02"], "use_global_settings": True},
        {"name": "pi-host-10", "ids": ["192.0.2.10", "00:53:00:00:00:01"], "use_global_settings": True},
        {"name": "Phone-28", "ids": ["02:00:53:00:00:28", "192.0.2.28"], "use_global_settings": True},
    ]
    to_del, to_add, to_upd = plan_sync(existing, desired, fresh=True)
    assert set(to_del) == {"pi-host", "pi-host-10"}, to_del
    assert [c["name"] for c in to_add] == ["Pi Gateway", "Workstation-Mini"], to_add
    assert len(to_upd) == 1 and to_upd[0] == ("Phone-28", {"name": "Phone", "ids": ["02:00:53:00:00:28", "192.0.2.28"], "use_global_settings": True}), to_upd

    # DHCP rotation / handoff: Device A moves .51 -> .59 while Device B claims .51
    inv_rot = {
        "fresh": True,
        "devices": [
            {"name": "phone-b", "ip": "192.0.2.51", "mac": "bb:cc:dd:ee:ff:02", "privacy_mac": False},
            {"name": "laptop-a", "ip": "192.0.2.59", "mac": "aa:bb:cc:dd:ee:01", "privacy_mac": False},
        ],
    }
    desired_rot = build_desired_clients(inv_rot)
    existing_rot = [
        {"name": "laptop-a", "ids": ["aa:bb:cc:dd:ee:01", "192.0.2.51"], "use_global_settings": False},
        {"name": "phone-b", "ids": ["bb:cc:dd:ee:ff:02"], "use_global_settings": True},
    ]
    del_r, add_r, upd_r = plan_sync(existing_rot, desired_rot, fresh=True)
    assert not del_r and not add_r
    upd_map = {n: p for n, p in upd_r}
    assert upd_map["laptop-a"]["ids"] == ["aa:bb:cc:dd:ee:01", "192.0.2.59"], upd_map
    assert upd_map["laptop-a"]["use_global_settings"] is False
    assert upd_map["phone-b"]["ids"] == ["bb:cc:dd:ee:ff:02", "192.0.2.51"], upd_map
    print("[sync-adguard-clients] self-check OK")


def main() -> int:
    if "--self-check" in sys.argv:
        self_check()
        return 0

    password = os.environ.get("AGH_ADMIN_PASSWORD", "")
    if not password:
        print("[sync-adguard-clients] SKIP: AGH_ADMIN_PASSWORD bos")
        return 0

    inv = load_modem_inventory(os.environ.get("MODEM_INVENTORY_PATH", ""))
    if not inv.get("present") or not inv.get("devices"):
        print("[sync-adguard-clients] SKIP: modem inventory yok")
        return 0

    pi_spec = build_pi_gateway_spec(
        os.environ.get("PI_STATIC_IP", ""),
        os.environ.get("PI_IPV6_ULA", ""),
        read_local_pi_macs(),
    )
    aliases = load_client_aliases(
        os.environ.get("ADGUARD_CLIENT_ALIASES_PATH", "/var/lib/pi-gateway/client-aliases.json")
    )
    nv4, nv6 = load_neigh_ips(os.environ.get("PI_INTERFACE", "eth0"))
    desired = build_desired_clients(
        inv, pi_spec=pi_spec, aliases=aliases, neigh_v4=nv4, neigh_v6=nv6
    )
    if not desired:
        print("[sync-adguard-clients] SKIP: eslenecek isimli cihaz yok")
        return 0

    port = os.environ.get("ADGUARD_WEB_PORT", "8080")
    user = os.environ.get("AGH_ADMIN_USER", "admin")
    base = f"http://127.0.0.1:{port}"
    try:
        client = AghClient(base, user, password)
        existing = client.get_clients()
        to_delete, to_add, to_update = plan_sync(
            existing, desired, fresh=bool(inv.get("fresh"))
        )
        deleted = added = updated = 0
        for cname in to_delete:
            try:
                client.delete_client(cname)
                deleted += 1
            except (OSError, urllib.error.URLError, ValueError) as exc:
                print(f"[sync-adguard-clients] WARN delete {cname}: {exc}", file=sys.stderr)
        for old_name, payload in to_update:
            try:
                client.update_client(old_name, payload)
                updated += 1
            except (OSError, urllib.error.URLError, ValueError) as exc:
                print(f"[sync-adguard-clients] WARN update {old_name}: {exc}", file=sys.stderr)
        for payload in to_add:
            try:
                client.add_client(payload)
                added += 1
            except (OSError, urllib.error.URLError, ValueError) as exc:
                print(f"[sync-adguard-clients] WARN add {payload.get('name')}: {exc}", file=sys.stderr)
        print(f"[sync-adguard-clients] OK deleted={deleted} added={added} updated={updated}")
    except (OSError, urllib.error.URLError, ValueError) as exc:
        print(f"[sync-adguard-clients] WARN: {exc}", file=sys.stderr)
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
