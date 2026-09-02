#!/usr/bin/env python3
"""AdGuard filter manifest reconcile — apply, governance check, self-check."""
from __future__ import annotations

import hashlib
import json
import os
import re
import subprocess
import sys
import time
import urllib.error
from datetime import datetime, timezone
from pathlib import Path
from typing import Any
from urllib.parse import quote, urljoin, urlsplit
from urllib.request import HTTPRedirectHandler, Request, build_opener

SCHEMA_VERSION = 2
SAMPLE_BYTES = 131072
MAX_SOURCE_BYTES = 128 * 1024 * 1024
DEFAULT_POLL_SEC = 180
DEFAULT_LOCK_WAIT_SEC = 120
ALLOWED_SOURCE_HOSTS = frozenset(
    {
        "adguardteam.github.io",
        "cdn.jsdelivr.net",
        "raw.githubusercontent.com",
    }
)


def log(msg: str) -> None:
    print(f"[adguard-filters] {msg}")


def log_err(msg: str) -> None:
    print(f"[adguard-filters] HATA: {msg}", file=sys.stderr)


class AguardApiError(RuntimeError):
    """Redacted, actionable AdGuard API failure."""


def mem_available_kb() -> int:
    try:
        with open("/proc/meminfo", encoding="utf-8") as fh:
            for line in fh:
                if line.startswith("MemAvailable:"):
                    return int(line.split()[1])
    except (OSError, ValueError, IndexError):
        pass
    return 0


def _epoch(value: Any) -> float | None:
    if value in (None, "", 0, "0"):
        return None
    try:
        number = float(value)
        return number / 1000 if number > 100000000000 else number
    except (TypeError, ValueError):
        try:
            return datetime.fromisoformat(str(value).replace("Z", "+00:00")).timestamp()
        except ValueError:
            return None


def _int_or_zero(value: Any) -> int:
    try:
        return int(value or 0)
    except (TypeError, ValueError):
        return 0


def load_manifest(
    remote_dir: str, profile: str
) -> tuple[list[tuple[str, str]], dict[str, Any], dict[str, Any], int]:
    manifest = Path(remote_dir) / "config/adguard/filter-lists.json"
    if not manifest.is_file():
        raise RuntimeError(f"{manifest} yok")
    data = json.loads(manifest.read_text())
    profiles = data.get("profiles", {})
    if profile not in profiles:
        raise RuntimeError(f"bilinmeyen profil {profile!r}")
    metadata = data.get("metadata") or {}
    regression = data.get("regression") or {}
    budgets = data.get("budgets") or {}
    try:
        max_total_rules = int(budgets.get(profile) or 0)
    except (TypeError, ValueError):
        max_total_rules = 0
    if max_total_rules < 1:
        raise RuntimeError(f"profil kural butcesi eksik: {profile!r}")
    desired: list[tuple[str, str]] = []
    seen_urls: set[str] = set()
    for entry in profiles[profile]:
        if not isinstance(entry, list) or len(entry) != 2:
            raise RuntimeError(f"gecersiz liste girdisi: {entry!r}")
        name, url = (str(entry[0]).strip(), str(entry[1]).strip())
        if not name or not url.startswith("https://") or url in seen_urls:
            raise RuntimeError(f"liste adi/URL gecersiz veya tekrarli: {entry!r}")
        if url not in metadata:
            raise RuntimeError(f"metadata eksik: {url}")
        seen_urls.add(url)
        desired.append((name, url))
    return desired, metadata, regression, max_total_rules


def load_user_rules(remote_dir: str) -> list[str]:
    rules_dir = Path(remote_dir) / "config/adguard"
    rules: list[str] = []
    for fname in ("user-rules.txt", "user-rules.local.txt"):
        path = rules_dir / fname
        if not path.is_file():
            continue
        for line in path.read_text().splitlines():
            line = line.strip()
            if line and not line.startswith("#"):
                rules.append(line)
    return rules


def source_cache_path() -> Path:
    return Path(
        os.environ.get(
            "ADGUARD_FILTER_SOURCE_CACHE_PATH",
            "/var/lib/pi-gateway/adguard-filter-source-cache.json",
        )
    )


def state_path() -> Path:
    return Path(
        os.environ.get(
            "ADGUARD_FILTER_STATE_PATH",
            "/var/lib/pi-gateway/adguard-filter-state.json",
        )
    )


def user_rules_hash_path() -> Path:
    return Path("/var/lib/pi-gateway/adguard-user-rules.sha256")


def _write_json(path: Path, payload: dict[str, Any]) -> None:
    path.parent.mkdir(parents=True, exist_ok=True)
    text = json.dumps(payload, ensure_ascii=False, indent=2) + "\n"
    try:
        path.write_text(text)
    except PermissionError:
        subprocess.run(
            ["sudo", "tee", str(path)],
            input=text,
            text=True,
            check=True,
            stdout=subprocess.DEVNULL,
        )
        subprocess.run(["sudo", "chmod", "644", str(path)], check=False)


def load_source_cache() -> dict[str, Any]:
    path = source_cache_path()
    if not path.is_file():
        return {"schema_version": 1, "sources": {}}
    try:
        data = json.loads(path.read_text())
    except (OSError, json.JSONDecodeError):
        return {"schema_version": 1, "sources": {}}
    if not isinstance(data, dict):
        return {"schema_version": 1, "sources": {}}
    data.setdefault("sources", {})
    return data


def save_source_cache(cache: dict[str, Any]) -> None:
    _write_json(source_cache_path(), cache)


def validate_source_sample(sample: str, url: str) -> None:
    if not sample.strip() or re.search(r"(?i)<(?:!doctype|html|head|body)\b", sample):
        raise RuntimeError("empty or HTML response")
    if not re.search(r"(?m)^\s*(?:!|#|0\.0\.0\.0|127\.0\.0\.1|::|@@?\|\||\|\|)", sample):
        raise RuntimeError("filter syntax marker not found")
    lines = [ln for ln in sample.splitlines() if ln.strip() and not ln.strip().startswith("#")]
    if len(lines) < 3:
        raise RuntimeError("sample too small")
    regex_rules = sum(1 for ln in lines if ln.strip().startswith("/") and ln.strip().endswith("/"))
    if regex_rules > max(20, len(lines) // 4):
        raise RuntimeError(f"regex-heavy sample ({regex_rules}/{len(lines)})")
    broad = sum(1 for ln in lines if re.search(r"\|\|[^|^]+/\^", ln))
    if broad > max(10, len(lines) // 10):
        raise RuntimeError(f"broad-domain sample ({broad}/{len(lines)})")


def source_line_delta_limit(
    old_lines: int, source_metadata: dict[str, Any] | None = None
) -> int:
    expected_max_lines = _int_or_zero((source_metadata or {}).get("max_rules")) * 2
    return max(500, old_lines // 2, expected_max_lines)


class _NoRedirect(HTTPRedirectHandler):
    def redirect_request(self, *args: Any, **kwargs: Any) -> None:
        return None


def validate_source_url(url: str) -> None:
    parsed = urlsplit(url)
    if parsed.scheme != "https" or parsed.hostname not in ALLOWED_SOURCE_HOSTS:
        raise RuntimeError(f"izin verilmeyen filter source: {url}")


def preflight_url(
    url: str, cache: dict[str, Any], source_metadata: dict[str, Any] | None = None
) -> bool:
    timeout = int(os.environ.get("ADGUARD_FILTER_PREFLIGHT_TIMEOUT_SEC", "20"))
    max_bytes = int(
        os.environ.get("ADGUARD_FILTER_MAX_SOURCE_BYTES", str(MAX_SOURCE_BYTES))
    )
    prev = (cache.get("sources") or {}).get(url) or {}
    headers = {"User-Agent": "Pi-Gateway filter preflight"}
    if prev.get("etag"):
        headers["If-None-Match"] = str(prev["etag"])
    if prev.get("last_modified"):
        headers["If-Modified-Since"] = str(prev["last_modified"])
    opener = build_opener(_NoRedirect)
    current_url = url
    response = None
    for _ in range(4):
        validate_source_url(current_url)
        request = Request(current_url, headers=headers)
        try:
            response = opener.open(request, timeout=timeout)
            break
        except urllib.error.HTTPError as exc:
            if exc.code == 304:
                log(f"preflight 304: {url}")
                return False
            if exc.code not in (301, 302, 303, 307, 308):
                raise RuntimeError(f"HTTP {exc.code}") from exc
            location = exc.headers.get("Location")
            if not location:
                raise RuntimeError(f"redirect location yok: {url}") from exc
            current_url = urljoin(current_url, location)
    if response is None:
        raise RuntimeError(f"redirect limiti asildi: {url}")
    with response:
        final_url = response.geturl()
        validate_source_url(final_url)
        code = getattr(response, "status", None) or response.getcode()
        if code == 304:
            log(f"preflight 304: {url}")
            return False
        content_length = response.headers.get("Content-Length")
        if content_length:
            try:
                if int(content_length) > max_bytes:
                    raise RuntimeError(f"source cok buyuk: {url}")
            except ValueError as exc:
                raise RuntimeError(f"source Content-Length gecersiz: {url}") from exc
        sample_parts: list[bytes] = []
        sample_size = 0
        total_bytes = 0
        total_lines = 0
        full_hash = hashlib.sha256()
        while True:
            chunk = response.read(1024 * 1024)
            if not chunk:
                break
            total_bytes += len(chunk)
            if total_bytes > max_bytes:
                raise RuntimeError(f"source cok buyuk: {url}")
            full_hash.update(chunk)
            total_lines += chunk.count(b"\n")
            if sample_size < SAMPLE_BYTES:
                part = chunk[: SAMPLE_BYTES - sample_size]
                sample_parts.append(part)
                sample_size += len(part)
        sample = b"".join(sample_parts).decode("utf-8", "replace")
        etag = response.headers.get("ETag")
        last_modified = response.headers.get("Last-Modified")
    validate_source_sample(sample, url)
    sample_digest = hashlib.sha256(sample.encode()).hexdigest()
    digest = full_hash.hexdigest()
    old_digest = prev.get("last_good_sha256") or prev.get("sha256")
    if old_digest:
        changed = old_digest != digest
    else:
        old_sample_digest = (
            prev.get("last_good_sha256_sample") or prev.get("sha256_sample")
        )
        changed = old_sample_digest != sample_digest
    old_guard_digest = old_digest or prev.get("last_good_sha256_sample") or prev.get(
        "sha256_sample"
    )
    if old_guard_digest and changed:
        old_lines = _int_or_zero(
            prev.get("last_good_line_count") or prev.get("line_count")
        )
        new_lines = total_lines
        delta_limit = source_line_delta_limit(old_lines, source_metadata)
        if old_lines and abs(new_lines - old_lines) > delta_limit:
            raise RuntimeError(
                f"sample delta too large: {url} ({old_lines}->{new_lines} satir)"
            )
    entry = {
        "etag": etag,
        "last_modified": last_modified,
        "sha256_sample": sample_digest,
        "sha256": digest,
        "line_count": total_lines,
        "checked_at": datetime.now(timezone.utc).isoformat(),
    }
    for key in (
        "last_good_sha256_sample",
        "last_good_sha256",
        "last_good_line_count",
        "last_good_etag",
        "last_good_last_modified",
        "last_good_at",
    ):
        if prev.get(key) is not None:
            entry[key] = prev[key]
    cache.setdefault("sources", {})[url] = entry
    log(f"preflight OK: {url}")
    return changed


def mark_source_cache_good(cache: dict[str, Any], urls: set[str]) -> None:
    now = datetime.now(timezone.utc).isoformat()
    for url in urls:
        entry = (cache.get("sources") or {}).get(url)
        if not isinstance(entry, dict) or not entry.get("sha256_sample"):
            continue
        entry["last_good_sha256_sample"] = entry["sha256_sample"]
        if entry.get("sha256"):
            entry["last_good_sha256"] = entry["sha256"]
        entry["last_good_line_count"] = entry.get("line_count", 0)
        entry["last_good_etag"] = entry.get("etag")
        entry["last_good_last_modified"] = entry.get("last_modified")
        entry["last_good_at"] = now


class AguardClient:
    def __init__(self, base: str, cookie: str) -> None:
        self.base = base
        self.cookie = cookie

    def api(self, path: str, method: str = "GET", payload: dict[str, Any] | None = None) -> dict[str, Any]:
        cmd = [
            "curl",
            "-fsS",
            "--max-time",
            "300",
            "-b",
            self.cookie,
            "-X",
            method,
            f"{self.base}{path}",
        ]
        if payload is not None:
            cmd += ["-H", "Content-Type: application/json", "-d", json.dumps(payload)]
        try:
            completed = subprocess.run(
                cmd,
                text=True,
                stdout=subprocess.PIPE,
                stderr=subprocess.PIPE,
                check=True,
            )
        except (OSError, subprocess.CalledProcessError) as exc:
            detail = ""
            if isinstance(exc, subprocess.CalledProcessError):
                detail = (exc.stderr or "").strip()[-200:]
                suffix = f": {detail}" if detail else ""
                raise AguardApiError(
                    f"{method} {path}: curl exit {exc.returncode}{suffix}"
                ) from exc
            raise AguardApiError(f"{method} {path}: curl calistirilamadi") from exc
        out = completed.stdout.strip()
        if not out:
            return {}
        if out[0] in "{[":
            try:
                data = json.loads(out)
            except json.JSONDecodeError as exc:
                raise AguardApiError(f"{method} {path}: gecersiz JSON") from exc
            return data if isinstance(data, dict) else {}
        first = out.split(None, 1)[0].lower()
        if first in ("ok", "true"):
            return {}
        raise AguardApiError(f"{method} {path}: AGH non-JSON response")

    def status(self) -> dict[str, Any]:
        return self.api("/control/filtering/status")

    def check_host(self, host: str) -> dict[str, Any]:
        return self.api(f"/control/filtering/check_host?name={quote(host, safe='')}")


def check_disk_regression_rules(rules: list[str], regression: dict[str, Any]) -> None:
    missing = [
        rule
        for rule in regression.get("must_allow", []) + regression.get("must_block", [])
        if rule not in rules
    ]
    if missing:
        raise RuntimeError(f"kritik user-rule eksik: {', '.join(missing)}")


def check_live_regressions(client: AguardClient, regression: dict[str, Any]) -> None:
    for host in regression.get("must_block_hosts", []):
        result = client.check_host(host)
        reason = str(result.get("reason") or "").lower()
        if "filtered" not in reason or "notfiltered" in reason:
            raise RuntimeError(f"beklenen block yok: {host} ({reason or 'bos'})")
    for host in regression.get("must_not_block_hosts", []):
        result = client.check_host(host)
        reason = str(result.get("reason") or "").lower()
        if "filtered" in reason and "notfiltered" not in reason:
            raise RuntimeError(f"medya block: {host} ({reason})")


def validate_filter_status(
    filter_status: dict[str, Any],
    desired: list[tuple[str, str]],
    metadata: dict[str, Any],
    max_total_rules: int = 0,
) -> tuple[list[str], list[str]]:
    live = {item.get("url"): item for item in filter_status.get("filters", []) if item.get("url")}
    errors: list[str] = []
    warnings: list[str] = []
    now = datetime.now(timezone.utc).timestamp()
    for name, url in desired:
        item = live.get(url)
        if not item:
            errors.append(f"{name}: status yok")
            continue
        if item.get("enabled") is not True:
            errors.append(f"{name}: disabled")
        count = _int_or_zero(item.get("rules_count"))
        meta = metadata[url]
        minimum = _int_or_zero(meta.get("min_rules"))
        maximum = _int_or_zero(meta.get("max_rules"))
        if count < minimum:
            errors.append(f"{name}: {count} < min {minimum}")
        if maximum and count > maximum:
            errors.append(f"{name}: {count} > max {maximum}")
        updated = _epoch(item.get("last_updated"))
        if updated is None:
            warnings.append(f"{name}: last_updated yok")
        else:
            max_age = _int_or_zero(meta.get("max_age_hours")) * 3600
            if max_age and now - updated > max_age:
                errors.append(f"{name}: liste yasi > {meta['max_age_hours']}h")
    total_rules = sum(
        _int_or_zero(live.get(url, {}).get("rules_count"))
        for _, url in desired
    )
    if max_total_rules and total_rules > max_total_rules:
        errors.append(f"profil kural butcesi asildi: {total_rules} > {max_total_rules}")
    return errors, warnings


def persist_user_rules_hash(digest: str) -> None:
    path = user_rules_hash_path()
    try:
        path.parent.mkdir(parents=True, exist_ok=True)
        path.write_text(digest + "\n")
    except PermissionError:
        subprocess.run(
            ["sudo", "tee", str(path)],
            input=digest + "\n",
            text=True,
            check=True,
            stdout=subprocess.DEVNULL,
        )
        subprocess.run(["sudo", "chmod", "644", str(path)], check=False)


def apply_user_rules(client: AguardClient, rules: list[str], status: dict[str, Any]) -> list[str]:
    failed: list[str] = []
    digest = hashlib.sha256("\n".join(rules).encode()).hexdigest()
    prev_digest = ""
    hash_file = user_rules_hash_path()
    if hash_file.is_file():
        try:
            prev_digest = hash_file.read_text().strip()
        except OSError:
            prev_digest = ""
    agh_rules = [
        r.strip()
        for r in (status.get("user_rules") or [])
        if isinstance(r, str) and r.strip() and not r.strip().startswith("#")
    ]
    agh_match = sorted(agh_rules) == sorted(rules)
    if digest == prev_digest and agh_match:
        log(f"user rules degismedi ({len(rules)} kural, set_rules atlandi)")
        return failed
    why: list[str] = []
    if digest != prev_digest:
        why.append("disk")
    if not agh_match:
        why.append(f"agh {len(agh_rules)}!={len(rules)}")
    try:
        client.api("/control/filtering/set_rules", "POST", {"rules": rules, "enabled": True})
    except (subprocess.CalledProcessError, RuntimeError) as exc:
        log_err(f"set_rules: {exc}")
        failed.append("set_rules")
        return failed
    persist_user_rules_hash(digest)
    log(f"user rules guncellendi ({len(rules)} kural, {','.join(why) or 'apply'})")
    try:
        client.api("/control/cache_clear", "POST")
        log("DNS cache temizlendi")
    except (subprocess.CalledProcessError, RuntimeError) as exc:
        log(f"WARN cache_clear: {exc}")
    return failed


def reconcile_desired_lists(
    client: AguardClient,
    desired: list[tuple[str, str]],
    current: dict[str, dict[str, Any]],
) -> tuple[int, int, bool]:
    added = 0
    enabled = 0
    changed = False
    for name, url in desired:
        item = current.get(url)
        if item is None:
            client.api(
                "/control/filtering/add_url",
                "POST",
                {"name": name, "url": url, "whitelist": False},
            )
            log(f"eklendi: {name}")
            added += 1
            changed = True
            continue
        if item.get("enabled") is not True:
            client.api(
                "/control/filtering/set_url",
                "POST",
                {
                    "url": url,
                    "whitelist": False,
                    "data": {"enabled": True, "name": name, "url": url},
                },
            )
            log(f"enable: {name}")
            enabled += 1
            changed = True
            continue
        log(f"mevcut: {name}")
    return added, enabled, changed


def remove_stale_lists(
    client: AguardClient,
    desired_urls: set[str],
    current: dict[str, dict[str, Any]],
) -> tuple[int, list[str]]:
    removed = 0
    failed: list[str] = []
    for url in sorted(set(current) - desired_urls):
        try:
            client.api("/control/filtering/remove_url", "POST", {"url": url})
            log(f"kaldirildi: {current[url].get('name', url)}")
            removed += 1
        except (subprocess.CalledProcessError, RuntimeError) as exc:
            log_err(f"kaldirilamadi: {url} ({exc})")
            failed.append(url)
    return removed, failed


def snapshot_live_state(status: dict[str, Any]) -> dict[str, Any]:
    return {
        "filters": [
            {
                key: item.get(key)
                for key in ("url", "name", "enabled", "whitelist")
                if key in item
            }
            for item in status.get("filters") or []
            if isinstance(item, dict) and item.get("url")
        ],
        "user_rules": list(status.get("user_rules") or [])
        if isinstance(status.get("user_rules") or [], list)
        else None,
    }


def restore_live_state(client: AguardClient, snapshot: dict[str, Any]) -> str | None:
    """Restore AGH list membership/settings and user rules after a partial apply."""
    try:
        current_status = client.status()
        current = {
            item.get("url"): item
            for item in current_status.get("filters") or []
            if isinstance(item, dict) and item.get("url")
        }
        wanted = {
            item.get("url"): item
            for item in snapshot.get("filters") or []
            if isinstance(item, dict) and item.get("url")
        }
        for url in sorted(set(current) - set(wanted)):
            client.api("/control/filtering/remove_url", "POST", {"url": url})
        for url, item in wanted.items():
            if url not in current:
                client.api(
                    "/control/filtering/add_url",
                    "POST",
                    {
                        "name": item.get("name") or url,
                        "url": url,
                        "whitelist": bool(item.get("whitelist", False)),
                    },
                )
            client.api(
                "/control/filtering/set_url",
                "POST",
                {
                    "url": url,
                    "whitelist": bool(item.get("whitelist", False)),
                    "data": {
                        "enabled": item.get("enabled") is True,
                        "name": item.get("name") or url,
                        "url": url,
                    },
                },
            )
        if isinstance(snapshot.get("user_rules"), list):
            client.api(
                "/control/filtering/set_rules",
                "POST",
                {"rules": snapshot["user_rules"], "enabled": True},
            )
        client.api("/control/filtering/refresh", "POST", {"whitelist": False})
        restored = client.status()
        restored_urls = {
            item.get("url")
            for item in restored.get("filters") or []
            if isinstance(item, dict)
        }
        if restored_urls != set(wanted):
            return "rollback filter membership dogrulanamadi"
        if isinstance(snapshot.get("user_rules"), list):
            actual_rules = [
                rule
                for rule in restored.get("user_rules") or []
                if isinstance(rule, str) and rule.strip()
            ]
            if sorted(actual_rules) != sorted(snapshot["user_rules"]):
                return "rollback user rules dogrulanamadi"
    except (AguardApiError, RuntimeError) as exc:
        return f"rollback API hatasi: {exc}"
    return None


def write_failure_state(profile: str, reason: str) -> None:
    previous = load_previous_state()
    now = datetime.now(timezone.utc).isoformat()
    payload = dict(previous)
    payload.update(
        {
            "schema_version": SCHEMA_VERSION,
            "checked_at": now,
            "last_success_at": previous.get("last_success_at"),
            "last_failure_at": now,
            "failure_reasons": [reason],
            "rollback_result": "not_attempted",
            "update_in_progress": False,
            "profile": profile,
        }
    )
    try:
        _write_json(state_path(), payload)
    except (OSError, subprocess.CalledProcessError) as exc:
        log_err(f"failure state yazilamadi: {exc}")


def refresh_verified(
    before: dict[str, Any],
    after: dict[str, Any],
    desired: list[tuple[str, str]],
) -> bool:
    before_by_url = {
        item.get("url"): item
        for item in before.get("filters") or []
        if isinstance(item, dict) and item.get("url")
    }
    after_by_url = {
        item.get("url"): item
        for item in after.get("filters") or []
        if isinstance(item, dict) and item.get("url")
    }
    changed = 0
    for _, url in desired:
        current = after_by_url.get(url)
        if not current:
            return False
        previous_ts = _epoch((before_by_url.get(url) or {}).get("last_updated"))
        current_ts = _epoch(current.get("last_updated"))
        if current_ts is None:
            return False
        if previous_ts is None or current_ts > previous_ts:
            changed += 1
    return changed > 0


def poll_validation(
    client: AguardClient,
    desired: list[tuple[str, str]],
    metadata: dict[str, Any],
    max_total_rules: int,
    *,
    needs_refresh: bool,
    previous_status: dict[str, Any] | None = None,
) -> tuple[dict[str, Any], list[str], list[str]]:
    poll_sec = int(os.environ.get("ADGUARD_FILTER_POLL_SEC", str(DEFAULT_POLL_SEC)))
    interval = max(2, int(os.environ.get("ADGUARD_FILTER_POLL_INTERVAL_SEC", "5")))
    deadline = time.time() + poll_sec
    status_after: dict[str, Any] = {}
    errors: list[str] = []
    warnings: list[str] = []
    refresh_attempts = 0
    status_failures = 0
    refresh_required = needs_refresh
    while time.time() < deadline:
        try:
            status_after = client.status()
            errors, warnings = validate_filter_status(
                status_after, desired, metadata, max_total_rules
            )
            if not errors and refresh_required and not refresh_verified(
                previous_status or {}, status_after, desired
            ):
                errors = ["refresh sonucu dogrulanamadi"]
            status_failures = 0
        except (AguardApiError, RuntimeError) as exc:
            status_failures += 1
            errors = [f"status okunamadi: {exc}"]
            warnings = []
            if status_failures >= 3:
                break
        if not errors:
            break
        max_refresh_attempts = 2 if refresh_required else 1
        if refresh_attempts < max_refresh_attempts:
            try:
                client.api("/control/filtering/refresh", "POST", {"whitelist": False})
                refresh_attempts += 1
                refresh_required = True
                log("gecersiz liste durumu — refresh istendi")
            except (AguardApiError, RuntimeError) as exc:
                refresh_attempts += 1
                log(f"WARN refresh: {exc}")
        if time.time() + interval >= deadline:
            break
        time.sleep(interval)
    if errors and time.time() >= deadline:
        log(f"WARN governance poll timeout ({poll_sec}s)")
    return status_after, errors, warnings


def build_state_payload(
    *,
    profile: str,
    manifest: Path,
    desired: list[tuple[str, str]],
    metadata: dict[str, Any],
    max_total_rules: int,
    status_after: dict[str, Any],
    duration_sec: float,
    mem_before_kb: int,
    mem_after_kb: int,
    success: bool,
    failure_reasons: list[str],
    previous_state: dict[str, Any] | None,
    rollback_result: str = "not_needed",
) -> dict[str, Any]:
    total_rules = sum(
        _int_or_zero(item.get("rules_count"))
        for item in status_after.get("filters", [])
        if item.get("url") in {url for _, url in desired}
    )
    now = datetime.now(timezone.utc).isoformat()
    prev_success = (previous_state or {}).get("last_success_at")
    payload: dict[str, Any] = {
        "schema_version": SCHEMA_VERSION,
        "checked_at": now,
        "last_success_at": now if success else prev_success,
        "last_failure_at": None if success else now,
        "failure_reasons": [] if success else failure_reasons,
        "rollback_result": rollback_result,
        "update_in_progress": False,
        "duration_sec": round(duration_sec, 2),
        "profile": profile,
        "max_total_rules": max_total_rules,
        "mem_available_mib_before": round(mem_before_kb / 1024) if mem_before_kb else None,
        "mem_available_mib_after": round(mem_after_kb / 1024) if mem_after_kb else None,
        "total_rules": total_rules,
        "manifest_sha256": hashlib.sha256(manifest.read_bytes()).hexdigest(),
        "filters": [
            {
                "name": name,
                "url": url,
                "category": metadata[url].get("category", "unknown"),
                "enabled": next(
                    (item.get("enabled") for item in status_after.get("filters", []) if item.get("url") == url),
                    False,
                ),
                "rules_count": next(
                    (item.get("rules_count", 0) for item in status_after.get("filters", []) if item.get("url") == url),
                    0,
                ),
                "last_updated": next(
                    (item.get("last_updated") for item in status_after.get("filters", []) if item.get("url") == url),
                    None,
                ),
            }
            for name, url in desired
        ],
    }
    if not success:
        payload["last_failure_at"] = now
    return payload


def load_previous_state() -> dict[str, Any]:
    path = state_path()
    if not path.is_file():
        return {}
    try:
        data = json.loads(path.read_text())
    except (OSError, json.JSONDecodeError):
        return {}
    return data if isinstance(data, dict) else {}


def apply_filters() -> int:
    base = os.environ["BASE"]
    cookie = os.environ["COOKIE"]
    remote_dir = os.environ["REMOTE_DIR"]
    profile = os.environ.get("ADGUARD_FILTER_PROFILE", "balanced")
    client = AguardClient(base, cookie)
    started = time.time()
    mem_before = mem_available_kb()
    failed: list[str] = []
    manifest_path = Path(remote_dir) / "config/adguard/filter-lists.json"

    desired, metadata, regression, max_total_rules = load_manifest(remote_dir, profile)
    desired_urls = {url for _, url in desired}
    rules = load_user_rules(remote_dir)
    check_disk_regression_rules(rules, regression)

    cache = load_source_cache()
    source_changed = False
    if os.environ.get("ADGUARD_FILTER_PREFLIGHT", "true") == "true":
        for _, url in desired:
            try:
                source_changed = preflight_url(url, cache, metadata.get(url)) or source_changed
            except (OSError, RuntimeError) as exc:
                log_err(f"preflight: {url} ({exc})")
                write_failure_state(profile, f"preflight: {url}")
                return 1
        save_source_cache(cache)

    try:
        status = client.status()
    except (AguardApiError, RuntimeError) as exc:
        reason = f"initial status: {exc}"
        log_err(reason)
        write_failure_state(profile, reason)
        return 1
    current = {f.get("url"): f for f in status.get("filters", []) if f.get("url")}
    live_snapshot = snapshot_live_state(status)

    # ponytail: stale once reconcile oncesi — TIF Full varken Medium eklenemez (OOM)
    removed_pre, remove_pre_failed = remove_stale_lists(client, desired_urls, current)
    failed.extend(remove_pre_failed)
    list_changed = bool(removed_pre)
    if removed_pre:
        log(f"reconcile oncesi stale kaldirildi: {removed_pre}")
        current = {url: item for url, item in current.items() if url in desired_urls}
        try:
            client.api("/control/filtering/refresh", "POST", {"whitelist": False})
            status = client.status()
            current = {f.get("url"): f for f in status.get("filters", []) if f.get("url")}
        except (AguardApiError, RuntimeError) as exc:
            log_err(f"post-remove refresh: {exc}")
            failed.append("post-remove-refresh")

    try:
        added, enabled, reconcile_changed = reconcile_desired_lists(client, desired, current)
    except (AguardApiError, RuntimeError) as exc:
        log_err(f"liste reconcile: {exc}")
        failed.append("list-reconcile")
        added = enabled = 0
        reconcile_changed = False
    list_changed = list_changed or reconcile_changed

    failed.extend(apply_user_rules(client, rules, status))
    log(f"profil={profile}")

    force_refresh = os.environ.get("ADGUARD_FILTER_FORCE_REFRESH", "false") == "true"
    scheduled_refresh = (
        os.environ.get("ADGUARD_FILTER_SCHEDULED_REFRESH", "false") == "true"
    )
    needs_refresh = bool(
        added or enabled or list_changed or source_changed or force_refresh
    )
    if scheduled_refresh and source_changed:
        log("scheduled refresh: kaynak degisti")
    if needs_refresh:
        try:
            client.api("/control/filtering/refresh", "POST", {"whitelist": False})
            log("filtreler yenileme istendi")
        except (subprocess.CalledProcessError, RuntimeError) as exc:
            log_err(f"refresh: {exc}")
            failed.append("refresh")
    else:
        log("filtre seti degismedi (refresh atlandi)")

    status_after, validation_errors, validation_warnings = poll_validation(
        client,
        desired,
        metadata,
        max_total_rules,
        needs_refresh=needs_refresh,
        previous_status=status,
    )
    for warning in validation_warnings:
        log(f"WARN: {warning}")
    if validation_errors:
        for error in validation_errors:
            log_err(error)
        failed.append("filter-governance")

    if not validation_errors:
        removed, remove_failed = remove_stale_lists(client, desired_urls, current)
        if removed:
            log(f"stale kaldirildi: {removed}")
        failed.extend(remove_failed)
        if removed:
            try:
                client.api("/control/filtering/refresh", "POST", {"whitelist": False})
            except (subprocess.CalledProcessError, RuntimeError):
                pass
            try:
                status_after = client.status()
                validation_errors, validation_warnings = validate_filter_status(
                    status_after, desired, metadata, max_total_rules
                )
            except (AguardApiError, RuntimeError) as exc:
                validation_errors = [f"post-remove status okunamadi: {exc}"]
                validation_warnings = []
            if validation_errors:
                for error in validation_errors:
                    log_err(error)
                failed.append("filter-governance-post-remove")

    total_rules = sum(
        _int_or_zero(item.get("rules_count"))
        for item in status_after.get("filters", [])
        if item.get("url") in desired_urls
    )
    log(f"toplam aktif profil kurali={total_rules}")

    mem_after = mem_available_kb()
    if profile == "aggressive" and mem_after and mem_after < 409600:
        log(f"WARN post-check MemAvailable={mem_after}kB — TIF Full OOM riski")

    if not failed:
        try:
            check_live_regressions(client, regression)
        except (AguardApiError, RuntimeError) as exc:
            log_err(f"refresh sonrasi kritik regression ({exc})")
            failed.append("filter-regression")

    rollback_result = "not_needed"
    if failed:
        rollback_error = restore_live_state(client, live_snapshot)
        if rollback_error:
            failed.append("rollback_failed")
            rollback_result = "failed"
            log_err(rollback_error)
        else:
            rollback_result = "ok"
            log("kismi apply geri alindi")

    previous_state = load_previous_state()
    success = not failed
    if success and os.environ.get("ADGUARD_FILTER_PREFLIGHT", "true") == "true":
        mark_source_cache_good(cache, desired_urls)
        try:
            save_source_cache(cache)
        except OSError as exc:
            log(f"WARN: source cache yazilamadi ({exc})")
    state_payload = build_state_payload(
        profile=profile,
        manifest=manifest_path,
        desired=desired,
        metadata=metadata,
        max_total_rules=max_total_rules,
        status_after=status_after,
        duration_sec=time.time() - started,
        mem_before_kb=mem_before,
        mem_after_kb=mem_after,
        success=success,
        failure_reasons=failed,
        previous_state=previous_state,
        rollback_result=rollback_result,
    )
    try:
        _write_json(state_path(), state_payload)
    except OSError as exc:
        log(f"WARN: governance state yazilamadi ({exc})")

    if failed:
        log_err(f"{len(failed)} islem basarisiz")
        return 1
    return 0


def governance_check() -> int:
    """Exit 0 when live AGH filters match manifest governance for current profile."""
    base = os.environ.get("BASE")
    cookie = os.environ.get("COOKIE")
    remote_dir = os.environ.get("REMOTE_DIR")
    profile = os.environ.get("ADGUARD_FILTER_PROFILE", "balanced")
    if not base or not cookie or not remote_dir:
        log_err("governance: BASE/COOKIE/REMOTE_DIR gerekli")
        return 2
    desired, metadata, _, max_total_rules = load_manifest(remote_dir, profile)
    client = AguardClient(base, cookie)
    try:
        status = client.status()
    except (AguardApiError, RuntimeError) as exc:
        log_err(f"governance status: {exc}")
        return 2
    errors, _warnings = validate_filter_status(
        status, desired, metadata, max_total_rules
    )
    state = load_previous_state()
    if state.get("failure_reasons"):
        errors.append(f"state: onceki apply basarisiz ({','.join(state['failure_reasons'])})")
    if errors:
        for error in errors:
            log_err(f"governance: {error}")
        return 1
    return 0


def self_check() -> None:
    sample_meta = {
        "https://example.test/list.txt": {
            "category": "test",
            "min_rules": 2,
            "max_rules": 100,
            "max_age_hours": 168,
        }
    }
    status = {
        "filters": [
            {
                "url": "https://example.test/list.txt",
                "name": "Test",
                "enabled": True,
                "rules_count": 10,
                "last_updated": datetime.now(timezone.utc).isoformat(),
            }
        ]
    }
    errors, _ = validate_filter_status(status, [("Test", "https://example.test/list.txt")], sample_meta)
    assert not errors
    errors, _ = validate_filter_status(
        status, [("Test", "https://example.test/list.txt")], sample_meta, 9
    )
    assert any("profil kural butcesi asildi" in error for error in errors)
    validate_source_sample(
        "||ads.example^\n||tracker.example^\n||bad.example^\n",
        "https://example.test/list.txt",
    )
    assert source_line_delta_limit(4687, {"max_rules": 4000000}) == 8000000
    bad = {"filters": [{"url": "https://example.test/list.txt", "enabled": False, "rules_count": 0}]}
    errors, _ = validate_filter_status(
        bad, [("Test", "https://example.test/list.txt")], sample_meta
    )
    assert any("disabled" in e for e in errors)
    cache = {
        "sources": {
            "https://example.test/list.txt": {"sha256_sample": "abc", "line_count": 3}
        }
    }
    mark_source_cache_good(cache, {"https://example.test/list.txt"})
    assert cache["sources"]["https://example.test/list.txt"]["last_good_sha256_sample"] == "abc"
    assert refresh_verified(
        {"filters": [{"url": "https://example.test/list.txt", "last_updated": 1}]},
        {"filters": [{"url": "https://example.test/list.txt", "last_updated": 2}]},
        [("Test", "https://example.test/list.txt")],
    )
    validate_source_url("https://adguardteam.github.io/list.txt")
    try:
        validate_source_url("http://evil.example/list.txt")
    except RuntimeError:
        pass
    else:
        raise AssertionError("insecure source accepted")
    from unittest.mock import patch

    with patch(
        "subprocess.run",
        side_effect=subprocess.CalledProcessError(
            22, ["curl"], stderr="HTTP 500"
        ),
    ):
        try:
            AguardClient("http://127.0.0.1", "/tmp/cookie").status()
        except AguardApiError as exc:
            assert "HTTP 500" in str(exc)
            assert "/tmp/cookie" not in str(exc)
        else:
            raise AssertionError("API failure not surfaced")

    class RedirectOpener:
        def open(self, request: Any, timeout: int) -> Any:
            raise urllib.error.HTTPError(
                request.full_url,
                302,
                "redirect",
                {"Location": "http://evil.example/list.txt"},
                None,
            )

    with patch(f"{__name__}.build_opener", return_value=RedirectOpener()):
        try:
            preflight_url("https://adguardteam.github.io/list.txt", {"sources": {}})
        except RuntimeError as exc:
            assert "izin verilmeyen" in str(exc)
        else:
            raise AssertionError("unsafe redirect accepted")
    import tempfile

    with tempfile.NamedTemporaryFile("w", suffix=".json", delete=False) as fh:
        json.dump({"profiles": {"balanced": [["Test", "https://example.test/list.txt"]]}}, fh)
        manifest_tmp = Path(fh.name)
    payload = build_state_payload(
        profile="balanced",
        manifest=manifest_tmp,
        desired=[("Test", "https://example.test/list.txt")],
        metadata=sample_meta,
        max_total_rules=100,
        status_after=status,
        duration_sec=1.2,
        mem_before_kb=512000,
        mem_after_kb=500000,
        success=True,
        failure_reasons=[],
        previous_state={},
    )
    assert payload["schema_version"] == SCHEMA_VERSION
    assert payload["last_success_at"]
    manifest_tmp.unlink(missing_ok=True)
    log("self-check OK")


def main() -> int:
    try:
        if "--self-check" in sys.argv:
            self_check()
            return 0
        if "--governance-check" in sys.argv:
            return governance_check()
        return apply_filters()
    except (AguardApiError, RuntimeError, OSError, json.JSONDecodeError) as exc:
        log_err(f"beklenmeyen apply hatasi: {exc}")
        return 1


if __name__ == "__main__":
    raise SystemExit(main())
