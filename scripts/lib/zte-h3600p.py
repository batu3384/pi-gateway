#!/usr/bin/env python3
"""Read-only ZTE H3600P client inventory adapter.

Firmware endpoints are private and can change without notice. Keep this
adapter fail-soft: a malformed or expired response must never replace the
last known snapshot.
"""
from __future__ import annotations

import argparse
import hashlib
import json
import os
import re
import sys
import tempfile
import time
import urllib.error
import urllib.parse
import urllib.request
from datetime import datetime, timezone
from http.cookiejar import CookieJar
from pathlib import Path
from typing import Any
from xml.etree import ElementTree as ET

SCHEMA_VERSION = 1
SUCCESS_MARKERS = frozenset({"", "OK", "SUCC", "SUCCESS"})
MAC_RE = re.compile(r"^(?:[0-9a-f]{2}[:-]){5}[0-9a-f]{2}$", re.I)
IP_RE = re.compile(r"^(?:\d{1,3}\.){3}\d{1,3}$")
FIELD_ALIASES = {
    "mac": "mac",
    "macaddr": "mac",
    "macaddress": "mac",
    "macaddrress": "mac",
    "ip": "ip",
    "ipaddress": "ip",
    "ipv4": "ip",
    "ipv4address": "ip",
    "hostname": "name",
    "host": "name",
    "name": "name",
    "devname": "name",
    "aliasname": "label",
    "label": "label",
    "networktype": "network",
    "accesstype": "network",
    "connectiontype": "network",
    "band": "band",
    "wifiband": "band",
    "frequency": "frequency",
    "channel": "channel",
    "essid": "ssid",
    "ssid": "ssid",
    "rssi": "rssi",
    "signalstrength": "rssi",
    "active": "active",
    "linktime": "link_time",
    "connecttime": "connect_time",
    "leasetime": "lease_time",
    "remainingleasetime": "lease_time",
}


class AdapterError(RuntimeError):
    """Expected router/session/response failure."""


def _local_name(tag: str) -> str:
    return tag.rsplit("}", 1)[-1].lower()


def _text(value: Any) -> str:
    return " ".join(str(value or "").replace("\x00", "").split())


def _field_name(value: Any) -> str:
    name = re.sub(r"[^a-z0-9]", "", _text(value).lower())
    if name.startswith("luquid"):
        name = name[len("luquid") :]
    return name


def normalize_mac(value: Any) -> str:
    raw = _text(value).lower().replace("-", ":")
    if not MAC_RE.fullmatch(raw):
        return ""
    return raw


def normalize_ip(value: Any) -> str:
    raw = _text(value)
    if not IP_RE.fullmatch(raw):
        return ""
    try:
        octets = [int(part) for part in raw.split(".")]
    except ValueError:
        return ""
    if any(part > 255 for part in octets):
        return ""
    return ".".join(str(part) for part in octets)


def clean_device_name(value: Any) -> str:
    name = _text(value)
    if (
        not name
        or name.lower() in {"?", "(name not found)", "unknown", "unknown device", "n/a", "-"}
        or IP_RE.fullmatch(name)
        or MAC_RE.fullmatch(name)
    ):
        return ""
    return name[:128]


def is_privacy_mac(mac: str) -> bool:
    try:
        return bool(int(mac.split(":", 1)[0], 16) & 0x02)
    except (AttributeError, ValueError, IndexError):
        return False


def _normalize_fields(fields: dict[str, Any], source: str) -> dict[str, Any]:
    out: dict[str, Any] = {"source": source}
    for key, value in fields.items():
        alias = FIELD_ALIASES.get(_field_name(key))
        if not alias:
            continue
        value_text = _text(value)
        if alias == "mac":
            out[alias] = normalize_mac(value_text)
        elif alias == "ip":
            out[alias] = normalize_ip(value_text)
        elif alias == "name" or alias == "label":
            out[alias] = clean_device_name(value_text)
        elif alias == "rssi":
            try:
                out[alias] = int(float(value_text))
            except (TypeError, ValueError):
                continue
        elif alias == "active":
            out[alias] = value_text.lower() in {"1", "true", "yes", "on", "connected"}
        else:
            out[alias] = value_text
    if not out.get("name"):
        out.pop("name", None)
    if not out.get("label"):
        out.pop("label", None)
    if not out.get("mac") and not out.get("ip"):
        return {}
    if out.get("label") and not out.get("name"):
        out["name"] = out["label"]
    out.setdefault("network", "unknown")
    return out


def _parse_xml_instances(payload: str, source: str) -> list[dict[str, Any]]:
    try:
        root = ET.fromstring(payload)
    except ET.ParseError as exc:
        raise AdapterError(f"XML parse failed: {exc}") from exc

    error = _text(root.findtext(".//IF_ERRORSTR"))
    if error and error.upper() not in SUCCESS_MARKERS:
        raise AdapterError(f"router response error: {error}")

    devices: list[dict[str, Any]] = []
    for instance in root.iter():
        if _local_name(instance.tag) != "instance":
            continue
        children = list(instance)
        fields: dict[str, str] = {}
        for index in range(0, len(children) - 1, 2):
            key = _text(children[index].text)
            value = _text(children[index + 1].text)
            if key:
                fields[key] = value
        device = _normalize_fields(fields, source)
        if device:
            devices.append(device)
    return devices


def _walk_json(value: Any, source: str, out: list[dict[str, Any]]) -> None:
    if isinstance(value, dict):
        fields = {
            str(key): item
            for key, item in value.items()
            if _field_name(key) in FIELD_ALIASES
        }
        device = _normalize_fields(fields, source)
        if device:
            out.append(device)
        for item in value.values():
            _walk_json(item, source, out)
    elif isinstance(value, list):
        for item in value:
            _walk_json(item, source, out)


def parse_response(payload: str, source: str) -> list[dict[str, Any]]:
    """Parse ZTE XML pair records or JSON records."""
    if not payload.strip():
        raise AdapterError(f"empty response: {source}")
    if payload.lstrip().startswith("<"):
        return _parse_xml_instances(payload, source)
    try:
        data = json.loads(payload)
    except json.JSONDecodeError as exc:
        raise AdapterError(f"unsupported response: {source}") from exc
    devices: list[dict[str, Any]] = []
    _walk_json(data, source, devices)
    return devices


def merge_devices(devices: list[dict[str, Any]]) -> list[dict[str, Any]]:
    """Merge endpoint duplicates by MAC first, then IP."""
    merged: dict[str, dict[str, Any]] = {}
    for device in devices:
        key = f"mac:{device['mac']}" if device.get("mac") else f"ip:{device['ip']}"
        current = merged.setdefault(key, {})
        for field, value in device.items():
            if value not in ("", None, "unknown"):
                if field == "name" and current.get("name"):
                    continue
                current[field] = value
        current.setdefault("source", device.get("source", "zte"))
    result = []
    for device in merged.values():
        if not device.get("name"):
            device["name"] = ""
        device["privacy_mac"] = is_privacy_mac(device.get("mac", ""))
        device["confidence"] = (
            "high" if device.get("mac") and device.get("ip") and device.get("name")
            else "medium" if device.get("mac")
            else "low"
        )
        device["last_seen"] = datetime.now(timezone.utc).isoformat()
        result.append(device)
    return sorted(result, key=lambda item: (item.get("ip", ""), item.get("mac", "")))


class ZteH3600P:
    """Minimal session client for the H288A-family web interface."""

    def __init__(self, base_url: str, username: str, password: str, timeout: float = 8) -> None:
        self.base_url = base_url.rstrip("/")
        self.username = username
        self.password = password
        self.timeout = timeout
        self.session_token = ""
        self.guid = int(time.time() * 1000)
        self.opener = urllib.request.build_opener(
            urllib.request.HTTPCookieProcessor(CookieJar())
        )

    def _next_guid(self) -> str:
        self.guid += 1
        return str(self.guid)

    def request(
        self,
        path: str,
        *,
        params: dict[str, Any] | None = None,
        form: dict[str, Any] | None = None,
    ) -> str:
        query = dict(params or {})
        query.setdefault("_", self._next_guid())
        url = f"{self.base_url}{path}"
        encoded = urllib.parse.urlencode(query)
        if encoded:
            url = f"{url}{'&' if '?' in url else '?'}{encoded}"
        data = urllib.parse.urlencode(form).encode() if form is not None else None
        request = urllib.request.Request(
            url,
            data=data,
            headers={
                "User-Agent": "Mozilla/5.0 Pi-Gateway modem inventory",
                "Accept": "application/json, text/xml, */*",
                "X-Requested-With": "XMLHttpRequest",
                "Referer": f"{self.base_url}/",
                "Content-Type": "application/x-www-form-urlencoded",
            },
            method="POST" if form is not None else "GET",
        )
        try:
            with self.opener.open(request, timeout=self.timeout) as response:
                payload = response.read(2_000_000).decode("utf-8", "replace")
        except (urllib.error.URLError, TimeoutError, OSError) as exc:
            raise AdapterError(f"router request failed: {exc}") from exc
        if "sessiontimeout" in payload.lower():
            raise AdapterError("router session expired")
        return payload

    def login(self) -> None:
        try:
            session_payload = json.loads(
                self.request(
                    "/",
                    params={"_type": "loginData", "_tag": "login_entry"},
                )
            )
        except (json.JSONDecodeError, AdapterError) as exc:
            raise AdapterError(f"session token unavailable: {exc}") from exc
        if int(session_payload.get("lockingTime") or 0) != 0:
            raise AdapterError("router login is locked")
        session_token = _text(session_payload.get("sess_token"))
        if not session_token:
            raise AdapterError("router session token empty")

        token_payload = self.request(
            "/",
            params={"_type": "loginData", "_tag": "login_token"},
        )
        try:
            token_root = ET.fromstring(token_payload)
        except ET.ParseError as exc:
            raise AdapterError(f"login token XML invalid: {exc}") from exc
        login_token = _text(token_root.text)
        if _local_name(token_root.tag) != "ajax_response_xml_root" or not login_token:
            raise AdapterError("login token empty or unexpected")

        password_hash = hashlib.sha256(
            f"{self.password}{login_token}".encode("utf-8")
        ).hexdigest()
        try:
            result = json.loads(
                self.request(
                    "/",
                    params={"_type": "loginData", "_tag": "login_entry"},
                    form={
                        "action": "login",
                        "Password": password_hash,
                        "Username": self.username,
                        "_sessionTOKEN": session_token,
                    },
                )
            )
        except (json.JSONDecodeError, AdapterError) as exc:
            raise AdapterError(f"login response invalid: {exc}") from exc
        # ZTE panel JS: login_need_refresh=true → reload (success); false → DisplayLoginErrorTip.
        if result.get("login_need_refresh") in (True, 1, "1"):
            self.session_token = _text(result.get("sess_token")) or session_token
            try:
                self.request("/")
            except AdapterError:
                pass
            return
        if result.get("lockingTime") not in (None, 0, "0"):
            raise AdapterError("router login rejected or locked")
        message = _text(result.get("loginErrMsg")) or "router login rejected"
        raise AdapterError(message)

    def logout(self) -> None:
        try:
            self.request(
                "/",
                params={"_type": "loginData", "_tag": "logout_entry"},
                form={"IF_LogOff": "1", "_sessionTOKEN": self.session_token},
            )
        except AdapterError:
            pass

    def fetch_devices(self) -> list[dict[str, Any]]:
        endpoints = (
            ("hiddenData", "accessdev_data", {"DeveiceType": "ALL"}, "ALL"),
            ("hiddenData", "accessdev_data", {"DeveiceType": "WLAN"}, "WLAN"),
            ("menuData", "Localnet_Lan_Clinet_lua.lua", {}, "LAN"),
            ("menuData", "accessdev_landevs_lua.lua", {}, "LAN"),
            ("menuData", "accessdev_ssiddev_lua.lua", {}, "WLAN"),
            ("menuData", "wlan_status_lua.lua", {}, "WLAN"),
            ("menuData", "topo_lua.lua", {"Action": "GetALLClients"}, "TOPOLOGY"),
        )
        raw: list[dict[str, Any]] = []
        for type_name, tag, extra_params, network in endpoints:
            try:
                payload = self.request(
                    "/",
                    params={"_type": type_name, "_tag": tag, **extra_params},
                )
                raw.extend(parse_response(payload, f"{tag}:{network}"))
            except AdapterError:
                continue
        devices = merge_devices(raw)
        if not devices:
            raise AdapterError("no valid device records in router responses")
        return devices


def write_snapshot(path: str, base_url: str, devices: list[dict[str, Any]]) -> None:
    destination = Path(path)
    destination.parent.mkdir(parents=True, exist_ok=True)
    snapshot = {
        "schema_version": SCHEMA_VERSION,
        "source": "zte-h3600p",
        "fetched_at": datetime.now(timezone.utc).isoformat(),
        "router": {"url": base_url},
        "devices": devices,
    }
    fd, temp_path = tempfile.mkstemp(
        prefix=f".{destination.name}.", suffix=".tmp", dir=destination.parent
    )
    try:
        with os.fdopen(fd, "w", encoding="utf-8") as handle:
            json.dump(snapshot, handle, ensure_ascii=False, indent=2)
            handle.write("\n")
        os.chmod(temp_path, 0o640)
        os.replace(temp_path, destination)
    finally:
        try:
            os.unlink(temp_path)
        except FileNotFoundError:
            pass


def self_check() -> None:
    xml = """
    <ajax_response_xml_root>
      <IF_ERRORSTR>SUCC</IF_ERRORSTR>
      <OBJ_ACCESSDEV_ID><Instance>
        <P>HostName</P><V>M2003J15SC</V>
        <P>IPAddress</P><V>192.0.2.10</V>
        <P>MACAddress</P><V>AA-BB-CC-DD-EE-01</V>
        <P>Active</P><V>1</V>
      </Instance></OBJ_ACCESSDEV_ID>
    </ajax_response_xml_root>
    """
    parsed = parse_response(xml, "fixture")
    assert parsed[0]["name"] == "M2003J15SC"
    assert parsed[0]["mac"] == "aa:bb:cc:dd:ee:01"
    assert parsed[0]["ip"] == "192.0.2.10"
    liquid = """
    <ajax_response_xml_root>
      <IF_ERRORSTR>SUCC</IF_ERRORSTR>
      <OBJ_ACCESSDEV_ID><Instance>
        <ParaName>_LuQUID_MACAddress</ParaName><ParaValue>AA-BB-CC-DD-EE-02</ParaValue>
        <ParaName>_LuQUID_HostName</ParaName><ParaValue>iPhone</ParaValue>
        <ParaName>_LuQUID_IPAddress</ParaName><ParaValue>192.0.2.20</ParaValue>
      </Instance></OBJ_ACCESSDEV_ID>
    </ajax_response_xml_root>
    """
    liquid_parsed = parse_response(liquid, "hiddenData")
    assert liquid_parsed[0]["name"] == "iPhone"
    assert liquid_parsed[0]["mac"] == "aa:bb:cc:dd:ee:02"
    merged = merge_devices(parsed + [{"mac": parsed[0]["mac"], "ip": "", "name": "M2003J15SC", "source": "topology"}])
    assert len(merged) == 1
    assert "last_seen" in merged[0]
    assert hashlib.sha256(b"secret-token").hexdigest()
    print("[zte-h3600p] self-check OK")


def main() -> int:
    parser = argparse.ArgumentParser(description="ZTE H3600P read-only inventory snapshot")
    parser.add_argument("--self-check", action="store_true")
    parser.add_argument("--output", default="")
    parser.add_argument("--url", default=os.environ.get("MODEM_URL", "http://192.168.1.1"))
    parser.add_argument("--username", default=os.environ.get("MODEM_USERNAME", ""))
    parser.add_argument("--password", default=os.environ.get("MODEM_PASSWORD", ""))
    parser.add_argument("--timeout", type=float, default=float(os.environ.get("MODEM_HTTP_TIMEOUT_SEC", "8")))
    args = parser.parse_args()
    if args.self_check:
        self_check()
        return 0
    if not args.output or not args.username or not args.password:
        print("[zte-h3600p] credentials/output missing", file=sys.stderr)
        return 2

    client = ZteH3600P(args.url, args.username, args.password, args.timeout)
    try:
        client.login()
        devices = client.fetch_devices()
        write_snapshot(args.output, args.url, devices)
    except AdapterError as exc:
        print(f"[zte-h3600p] snapshot not updated: {exc}", file=sys.stderr)
        return 1
    finally:
        client.logout()
    print(f"[zte-h3600p] snapshot updated: {len(devices)} devices")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
