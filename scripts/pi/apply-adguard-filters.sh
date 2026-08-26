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
export BASE COOKIE REMOTE_DIR ADGUARD_FILTER_PROFILE
python3 - <<'PY'
import hashlib, json, os, subprocess, sys
from pathlib import Path

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
desired = [(name, url) for name, url in profiles[profile]]
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

def api(path, method="GET", payload=None):
    cmd = ["curl", "-fsS", "--max-time", "300", "-b", cookie, "-X", method, f"{base}{path}"]
    if payload is not None:
        cmd += ["-H", "Content-Type: application/json", "-d", json.dumps(payload)]
    out = subprocess.check_output(cmd, text=True).strip()
    # ponytail: AGH add/remove_url often 200 + empty/"OK", not JSON
    if not out:
        return {}
    if out[0] in "{[":
        return json.loads(out)
    if out in ("OK", "ok", "true", "True"):
        return {}
    raise RuntimeError(f"AGH non-JSON: {out[:200]}")

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

rules_digest = hashlib.sha256("\n".join(rules).encode()).hexdigest()
prev_digest = ""
if hash_file.is_file():
    try:
        prev_digest = hash_file.read_text().strip()
    except OSError:
        prev_digest = ""
if rules_digest == prev_digest:
    print(f"[adguard-filters] user rules degismedi ({len(rules)} kural, set_rules atlandi)")
else:
    try:
        api("/control/filtering/set_rules", "POST", {"rules": rules, "enabled": True})
    except (subprocess.CalledProcessError, RuntimeError) as exc:
        print(f"[adguard-filters] HATA set_rules: {exc}", file=sys.stderr)
        failed.append("set_rules")
    else:
        hash_file.parent.mkdir(parents=True, exist_ok=True)
        try:
            hash_file.write_text(rules_digest + "\n")
        except PermissionError:
            subprocess.run(
                ["sudo", "tee", str(hash_file)],
                input=rules_digest + "\n",
                text=True,
                check=True,
                stdout=subprocess.DEVNULL,
            )
            subprocess.run(["sudo", "chmod", "644", str(hash_file)], check=False)
        print(f"[adguard-filters] user rules guncellendi ({len(rules)} kural)")

print(f"[adguard-filters] profil={profile}")
if added or removed:
    api("/control/filtering/refresh", "POST", {"whitelist": False})
    print("[adguard-filters] filtreler yenilendi")
else:
    print("[adguard-filters] filtre seti degismedi")
if failed:
    print(f"[adguard-filters] HATA: {len(failed)} islem basarisiz", file=sys.stderr)
    sys.exit(1)
PY
if [[ -x "$SCRIPT_DIR/apply-adguard-rewrites.sh" ]]; then
  bash "$SCRIPT_DIR/apply-adguard-rewrites.sh"
fi
log "Tamamlandi"
