#!/usr/bin/env bash
# AdGuard filtre seti — idempotent (yalnizca fark uygular)
set -euo pipefail
REMOTE_DIR="${REMOTE_DIR:-/home/${USER}/pi-gateway}"
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
_PG_ENV_LIB="${SCRIPT_DIR}/../lib/env-file.sh"
PG_SCRIPT_NAME="$(basename "$0")"
# shellcheck source=../lib/env-file.sh
source "${_PG_ENV_LIB:?}"
read_remote_dotenv || { echo "[${PG_SCRIPT_NAME:-script}] HATA: .env dotenv parser hatasi" >&2; exit 1; }
source "$SCRIPT_DIR/../lib/adguard-api.sh"
AGH_ADMIN_USER="${AGH_ADMIN_USER:-admin}"
AGH_ADMIN_PASSWORD="${AGH_ADMIN_PASSWORD:-}"
ADGUARD_WEB_PORT="${ADGUARD_WEB_PORT:-8080}"
ADGUARD_FILTER_PROFILE="${ADGUARD_FILTER_PROFILE:-balanced}"
BASE="http://127.0.0.1:${ADGUARD_WEB_PORT}"
[[ -n "$AGH_ADMIN_PASSWORD" ]] || { echo "[adguard-filters] AGH_ADMIN_PASSWORD bos"; exit 1; }
COOKIE="$(mktemp)"
trap 'rm -f "$COOKIE"' EXIT
log() { echo "[adguard-filters] $*"; }
login() {
  agh_login "$BASE" "$COOKIE" "$AGH_ADMIN_USER" "$AGH_ADMIN_PASSWORD"
}
login || { log "AdGuard login basarisiz"; exit 1; }
# ponytail: TIF Full ~2.1M rules. Ceiling ~400MiB Available; upgrade: ADGUARD_FILTER_PROFILE=balanced.
if [[ "$ADGUARD_FILTER_PROFILE" == "aggressive" ]]; then
  _avail_kb="$(awk '/MemAvailable:/ {print $2; exit}' /proc/meminfo 2>/dev/null || echo 0)"
  if [[ "${_avail_kb:-0}" -gt 0 && "${_avail_kb}" -lt 409600 ]]; then
    log "WARN MemAvailable ${_avail_kb}kB — TIF Full OOM risk; set ADGUARD_FILTER_PROFILE=balanced"
  fi
  unset _avail_kb
fi
export BASE COOKIE REMOTE_DIR ADGUARD_FILTER_PROFILE
python3 - <<'PY'
import hashlib, json, os, re, subprocess, sys, time
from datetime import datetime, timezone
from pathlib import Path
from urllib.parse import quote
from urllib.request import Request, urlopen

base = os.environ["BASE"]
cookie = os.environ["COOKIE"]
remote_dir = os.environ["REMOTE_DIR"]
profile = os.environ.get("ADGUARD_FILTER_PROFILE", "balanced")
rules_dir = Path(remote_dir) / "config/adguard"
manifest = rules_dir / "filter-lists.json"
hash_file = Path("/var/lib/pi-gateway/adguard-user-rules.sha256")

if not manifest.is_file():
    print(f"[adguard-filters] HATA: {manifest} yok", file=sys.stderr)
    sys.exit(1)

data = json.loads(manifest.read_text())
profiles = data.get("profiles", {})
if profile not in profiles:
    print(f"[adguard-filters] HATA: bilinmeyen profil {profile!r}", file=sys.stderr)
    sys.exit(1)
metadata = data.get("metadata") or {}
regression = data.get("regression") or {}
desired = []
seen_urls = set()
for entry in profiles[profile]:
    if not isinstance(entry, list) or len(entry) != 2:
        print(f"[adguard-filters] HATA: gecersiz liste girdisi: {entry!r}", file=sys.stderr)
        sys.exit(1)
    name, url = (str(entry[0]).strip(), str(entry[1]).strip())
    if not name or not url.startswith("https://") or url in seen_urls:
        print(f"[adguard-filters] HATA: liste adi/URL gecersiz veya tekrarli: {entry!r}", file=sys.stderr)
        sys.exit(1)
    if url not in metadata:
        print(f"[adguard-filters] HATA: metadata eksik: {url}", file=sys.stderr)
        sys.exit(1)
    seen_urls.add(url)
    desired.append((name, url))
desired_urls = {url for _, url in desired}

rules = []
for fname in ("user-rules.txt", "user-rules.local.txt"):
    path = rules_dir / fname
    if not path.is_file():
        continue
    for line in path.read_text().splitlines():
        line = line.strip()
        if line and not line.startswith("#"):
            rules.append(line)

def preflight_url(url):
    request = Request(
        url,
        headers={"User-Agent": "Pi-Gateway filter preflight", "Range": "bytes=0-131071"},
    )
    with urlopen(request, timeout=int(os.environ.get("ADGUARD_FILTER_PREFLIGHT_TIMEOUT_SEC", "20"))) as response:
        sample = response.read(131072).decode("utf-8", "replace")
    if not sample.strip() or re.search(r"(?i)<(?:!doctype|html|head|body)\b", sample):
        raise RuntimeError("empty or HTML response")
    if not re.search(r"(?m)^\s*(?:!|#|0\.0\.0\.0|127\.0\.0\.1|::|@@?\|\||\|\|)", sample):
        raise RuntimeError("filter syntax marker not found")

if os.environ.get("ADGUARD_FILTER_PREFLIGHT", "true") == "true":
    for _, url in desired:
        try:
            preflight_url(url)
            print(f"[adguard-filters] preflight OK: {url}")
        except (OSError, RuntimeError) as exc:
            print(f"[adguard-filters] HATA preflight: {url} ({exc})", file=sys.stderr)
            sys.exit(1)

def api(path, method="GET", payload=None):
    cmd = ["curl", "-fsS", "--max-time", "300", "-b", cookie, "-X", method, f"{base}{path}"]
    if payload is not None:
        cmd += ["-H", "Content-Type: application/json", "-d", json.dumps(payload)]
    out = subprocess.check_output(cmd, text=True).strip()
    # ponytail: AGH add/remove_url often 200 + empty/"OK"/"OK 93 rules", not JSON
    if not out:
        return {}
    if out[0] in "{[":
        return json.loads(out)
    first = out.split(None, 1)[0].lower()
    if first in ("ok", "true"):
        return {}
    raise RuntimeError(f"AGH non-JSON: {out[:200]}")

missing_regression = [
    rule for rule in regression.get("must_allow", []) + regression.get("must_block", [])
    if rule not in rules
]
if missing_regression:
    print(
        f"[adguard-filters] HATA: kritik user-rule eksik: {', '.join(missing_regression)}",
        file=sys.stderr,
    )
    sys.exit(1)

def check_host(host):
    return api(f"/control/filtering/check_host?name={quote(host, safe='')}")

def check_regressions():
    for host in regression.get("must_block_hosts", []):
        result = check_host(host)
        reason = str(result.get("reason") or "").lower()
        if "filtered" not in reason or "notfiltered" in reason:
            raise RuntimeError(f"beklenen block yok: {host} ({reason or 'bos'})")
    for host in regression.get("must_not_block_hosts", []):
        result = check_host(host)
        reason = str(result.get("reason") or "").lower()
        if "filtered" in reason and "notfiltered" not in reason:
            raise RuntimeError(f"medya block: {host} ({reason})")

try:
    check_regressions()
except (subprocess.CalledProcessError, RuntimeError, json.JSONDecodeError) as exc:
    print(f"[adguard-filters] HATA: kritik regression ({exc})", file=sys.stderr)
    sys.exit(1)

status = api("/control/filtering/status")
current = {f.get("url"): f for f in status.get("filters", []) if f.get("url")}
removed = added = 0
failed = []
for url in sorted(set(current) - desired_urls):
    try:
        api("/control/filtering/remove_url", "POST", {"url": url})
        print(f"[adguard-filters] kaldirildi: {current[url].get('name', url)}")
        removed += 1
    except (subprocess.CalledProcessError, RuntimeError) as exc:
        print(f"[adguard-filters] HATA kaldirilamadi: {url} ({exc})", file=sys.stderr)
        failed.append(url)
for name, url in desired:
    if url in current:
        print(f"[adguard-filters] mevcut: {name}")
        continue
    try:
        api("/control/filtering/add_url", "POST", {"name": name, "url": url, "whitelist": False})
        print(f"[adguard-filters] eklendi: {name}")
        added += 1
    except (subprocess.CalledProcessError, RuntimeError) as exc:
        print(f"[adguard-filters] HATA eklenemedi: {name} ({exc})", file=sys.stderr)
        failed.append(name)

def persist_hash(digest: str) -> None:
    hash_file.parent.mkdir(parents=True, exist_ok=True)
    try:
        hash_file.write_text(digest + "\n")
    except PermissionError:
        subprocess.run(
            ["sudo", "tee", str(hash_file)],
            input=digest + "\n",
            text=True,
            check=True,
            stdout=subprocess.DEVNULL,
        )
        subprocess.run(["sudo", "chmod", "644", str(hash_file)], check=False)


rules_digest = hashlib.sha256("\n".join(rules).encode()).hexdigest()
prev_digest = ""
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
# Hash tek basina yetmez: AGH kopyasi dusebilir, timer set_rules atlar.
agh_match = sorted(agh_rules) == sorted(rules)
if rules_digest == prev_digest and agh_match:
    print(f"[adguard-filters] user rules degismedi ({len(rules)} kural, set_rules atlandi)")
else:
    why = []
    if rules_digest != prev_digest:
        why.append("disk")
    if not agh_match:
        why.append(f"agh {len(agh_rules)}!={len(rules)}")
    try:
        api("/control/filtering/set_rules", "POST", {"rules": rules, "enabled": True})
    except (subprocess.CalledProcessError, RuntimeError) as exc:
        print(f"[adguard-filters] HATA set_rules: {exc}", file=sys.stderr)
        failed.append("set_rules")
    else:
        persist_hash(rules_digest)
        print(
            f"[adguard-filters] user rules guncellendi ({len(rules)} kural, {','.join(why) or 'apply'})"
        )
        try:
            api("/control/cache_clear", "POST")
            print("[adguard-filters] DNS cache temizlendi")
        except (subprocess.CalledProcessError, RuntimeError) as exc:
            print(f"[adguard-filters] WARN cache_clear: {exc}", file=sys.stderr)

print(f"[adguard-filters] profil={profile}")
force_refresh = os.environ.get("ADGUARD_FILTER_FORCE_REFRESH", "false") == "true"
if added or removed or force_refresh:
    api("/control/filtering/refresh", "POST", {"whitelist": False})
    print("[adguard-filters] filtreler yenileme istendi")
else:
    print("[adguard-filters] filtre seti degismedi")

def _epoch(value):
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

def _int_or_zero(value):
    try:
        return int(value or 0)
    except (TypeError, ValueError):
        return 0

def validate_filter_status(filter_status):
    live = {item.get("url"): item for item in filter_status.get("filters", []) if item.get("url")}
    errors = []
    warnings = []
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
    return errors, warnings

# AGH refresh is asynchronous on some versions; poll status before declaring green.
status_after = status
validation_errors, validation_warnings = validate_filter_status(status_after)
if added or removed or force_refresh or validation_errors:
    for _ in range(4):
        if validation_errors and not (added or removed or force_refresh):
            api("/control/filtering/refresh", "POST", {"whitelist": False})
            print("[adguard-filters] gecersiz liste durumu — refresh istendi")
        time.sleep(2)
        status_after = api("/control/filtering/status")
        validation_errors, validation_warnings = validate_filter_status(status_after)
        if not validation_errors:
            break
if validation_warnings:
    for warning in validation_warnings:
        print(f"[adguard-filters] WARN: {warning}")
if validation_errors:
    for error in validation_errors:
        print(f"[adguard-filters] HATA: {error}", file=sys.stderr)
    failed.append("filter-governance")
total_rules = sum(
    _int_or_zero(item.get("rules_count"))
    for item in status_after.get("filters", [])
    if item.get("url") in desired_urls
)
print(f"[adguard-filters] toplam aktif profil kurali={total_rules}")
try:
    with open("/proc/meminfo", encoding="utf-8") as meminfo:
        available_kb = next(
            int(line.split()[1])
            for line in meminfo
            if line.startswith("MemAvailable:")
        )
except (OSError, StopIteration, ValueError):
    available_kb = 0
if profile == "aggressive" and available_kb and available_kb < 409600:
    print(
        f"[adguard-filters] WARN post-check MemAvailable={available_kb}kB — "
        "TIF Full OOM riski"
    )

try:
    check_regressions()
except (subprocess.CalledProcessError, RuntimeError, json.JSONDecodeError) as exc:
    print(f"[adguard-filters] HATA: refresh sonrasi kritik regression ({exc})", file=sys.stderr)
    failed.append("filter-regression")

state_file = Path(os.environ.get("ADGUARD_FILTER_STATE_PATH", "/var/lib/pi-gateway/adguard-filter-state.json"))
state_payload = {
    "schema_version": 1,
    "checked_at": datetime.now(timezone.utc).isoformat(),
    "profile": profile,
    "mem_available_mib": round(available_kb / 1024) if available_kb else None,
    "total_rules": total_rules,
    "manifest_sha256": hashlib.sha256(manifest.read_bytes()).hexdigest(),
    "filters": [
        {
            "name": name,
            "url": url,
            "category": metadata[url].get("category", "unknown"),
            "enabled": next((item.get("enabled") for item in status_after.get("filters", []) if item.get("url") == url), False),
            "rules_count": next((item.get("rules_count", 0) for item in status_after.get("filters", []) if item.get("url") == url), 0),
            "last_updated": next((item.get("last_updated") for item in status_after.get("filters", []) if item.get("url") == url), None),
        }
        for name, url in desired
    ],
}
try:
    state_file.parent.mkdir(parents=True, exist_ok=True)
    state_file.write_text(json.dumps(state_payload, ensure_ascii=False, indent=2) + "\n")
except OSError as exc:
    print(f"[adguard-filters] WARN: governance state yazilamadi ({exc})", file=sys.stderr)

if failed:
    print(f"[adguard-filters] HATA: {len(failed)} islem basarisiz", file=sys.stderr)
    sys.exit(1)
PY
if [[ -x "$SCRIPT_DIR/apply-adguard-rewrites.sh" ]]; then
  bash "$SCRIPT_DIR/apply-adguard-rewrites.sh"
fi
log "Tamamlandi"
