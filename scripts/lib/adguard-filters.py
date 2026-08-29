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
from urllib.parse import quote
from urllib.request import Request, urlopen

SCHEMA_VERSION = 2
SAMPLE_BYTES = 131072
DEFAULT_POLL_SEC = 180
DEFAULT_LOCK_WAIT_SEC = 120


def log(msg: str) -> None:
    print(f"[adguard-filters] {msg}")


def log_err(msg: str) -> None:
    print(f"[adguard-filters] HATA: {msg}", file=sys.stderr)


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


def preflight_url(url: str, cache: dict[str, Any]) -> None:
    timeout = int(os.environ.get("ADGUARD_FILTER_PREFLIGHT_TIMEOUT_SEC", "20"))
    prev = (cache.get("sources") or {}).get(url) or {}
    headers = {"User-Agent": "Pi-Gateway filter preflight"}
    if prev.get("etag"):
        headers["If-None-Match"] = str(prev["etag"])
    if prev.get("last_modified"):
        headers["If-Modified-Since"] = str(prev["last_modified"])
    request = Request(url, headers=headers)
    try:
        with urlopen(request, timeout=timeout) as response:
            code = getattr(response, "status", None) or response.getcode()
            if code == 304:
                log(f"preflight 304: {url}")
                return
            sample = response.read(SAMPLE_BYTES).decode("utf-8", "replace")
            etag = response.headers.get("ETag")
            last_modified = response.headers.get("Last-Modified")
    except urllib.error.HTTPError as exc:
        if exc.code == 304:
            log(f"preflight 304: {url}")
            return
        raise RuntimeError(f"HTTP {exc.code}") from exc
    validate_source_sample(sample, url)
    digest = hashlib.sha256(sample.encode()).hexdigest()
    old_digest = prev.get("last_good_sha256_sample") or prev.get("sha256_sample")
    if old_digest and old_digest != digest:
        old_lines = _int_or_zero(
            prev.get("last_good_line_count") or prev.get("line_count")
        )
        new_lines = len([ln for ln in sample.splitlines() if ln.strip()])
        if old_lines and abs(new_lines - old_lines) > max(500, old_lines // 2):
            raise RuntimeError(
                f"sample delta too large: {url} ({old_lines}->{new_lines} satir)"
            )
    entry = {
        "etag": etag,
        "last_modified": last_modified,
        "sha256_sample": digest,
        "line_count": len([ln for ln in sample.splitlines() if ln.strip()]),
        "checked_at": datetime.now(timezone.utc).isoformat(),
    }
    for key in (
        "last_good_sha256_sample",
        "last_good_line_count",
        "last_good_etag",
        "last_good_last_modified",
        "last_good_at",
    ):
        if prev.get(key) is not None:
            entry[key] = prev[key]
    cache.setdefault("sources", {})[url] = entry
    log(f"preflight OK: {url}")


def mark_source_cache_good(cache: dict[str, Any], urls: set[str]) -> None:
    now = datetime.now(timezone.utc).isoformat()
    for url in urls:
        entry = (cache.get("sources") or {}).get(url)
        if not isinstance(entry, dict) or not entry.get("sha256_sample"):
            continue
        entry["last_good_sha256_sample"] = entry["sha256_sample"]
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
        out = subprocess.check_output(cmd, text=True).strip()
        if not out:
            return {}
        if out[0] in "{[":
            data = json.loads(out)
            return data if isinstance(data, dict) else {}
        first = out.split(None, 1)[0].lower()
        if first in ("ok", "true"):
            return {}
        raise RuntimeError(f"AGH non-JSON: {out[:200]}")

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


def poll_validation(
    client: AguardClient,
    desired: list[tuple[str, str]],
    metadata: dict[str, Any],
    max_total_rules: int,
    *,
    needs_refresh: bool,
) -> tuple[dict[str, Any], list[str], list[str]]:
    poll_sec = int(os.environ.get("ADGUARD_FILTER_POLL_SEC", str(DEFAULT_POLL_SEC)))
    interval = max(2, int(os.environ.get("ADGUARD_FILTER_POLL_INTERVAL_SEC", "5")))
    deadline = time.time() + poll_sec
    status_after = client.status()
    errors, warnings = validate_filter_status(
        status_after, desired, metadata, max_total_rules
    )
    while time.time() < deadline:
        if not errors:
            break
        if not needs_refresh:
            try:
                client.api("/control/filtering/refresh", "POST", {"whitelist": False})
                log("gecersiz liste durumu — refresh istendi")
            except (subprocess.CalledProcessError, RuntimeError) as exc:
                log(f"WARN refresh: {exc}")
        time.sleep(interval)
        status_after = client.status()
        errors, warnings = validate_filter_status(
            status_after, desired, metadata, max_total_rules
        )
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
    if os.environ.get("ADGUARD_FILTER_PREFLIGHT", "true") == "true":
        for _, url in desired:
            try:
                preflight_url(url, cache)
            except (OSError, RuntimeError) as exc:
                log_err(f"preflight: {url} ({exc})")
                return 1
        save_source_cache(cache)

    status = client.status()
    current = {f.get("url"): f for f in status.get("filters", []) if f.get("url")}

    try:
        added, enabled, list_changed = reconcile_desired_lists(client, desired, current)
    except (subprocess.CalledProcessError, RuntimeError) as exc:
        log_err(f"liste reconcile: {exc}")
        return 1

    failed.extend(apply_user_rules(client, rules, status))
    log(f"profil={profile}")

    force_refresh = os.environ.get("ADGUARD_FILTER_FORCE_REFRESH", "false") == "true"
    needs_refresh = bool(added or enabled or list_changed or force_refresh)
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
            status_after = client.status()
            validation_errors, validation_warnings = validate_filter_status(
                status_after, desired, metadata, max_total_rules
            )
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
        except (subprocess.CalledProcessError, RuntimeError, json.JSONDecodeError) as exc:
            log_err(f"refresh sonrasi kritik regression ({exc})")
            failed.append("filter-regression")

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
    status = client.status()
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
    if "--self-check" in sys.argv:
        self_check()
        return 0
    if "--governance-check" in sys.argv:
        return governance_check()
    return apply_filters()


if __name__ == "__main__":
    raise SystemExit(main())
