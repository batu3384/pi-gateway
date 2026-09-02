#!/usr/bin/env bash
# Docker restart loop algilama — health-check'ten bagimsiz, 5dk.
set -euo pipefail
REMOTE_DIR="${REMOTE_DIR:-/home/${USER}/pi-gateway}"
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=../lib/env-file.sh
source "$SCRIPT_DIR/../lib/env-file.sh"
read_remote_dotenv || { echo "[container-watch] HATA: .env" >&2; exit 1; }
load_telegram_from_hermes || true
# shellcheck source=../lib/notify.sh
source "$SCRIPT_DIR/../lib/notify.sh"

THRESHOLD="${CONTAINER_RESTART_ALERT_THRESHOLD:-3}"
REPEAT_SEC="${CONTAINER_RESTART_REPEAT_SEC:-21600}"
STATE="${CONTAINER_WATCH_STATE_PATH:-/var/lib/pi-gateway/container-watch-state.json}"
WATCH="${CONTAINER_WATCH_LIST:-prometheus grafana n8n adguard unbound caddy crowdsec netalertx}"

log() { echo "[container-watch] $*"; }

if [[ "${1:-}" == "--self-check" ]]; then
  [[ "$THRESHOLD" =~ ^[0-9]+$ ]] || exit 1
  grep -q 'notify_container_restart' "$SCRIPT_DIR/../lib/notify.sh" || exit 1
  log "self-check OK"
  exit 0
fi

notify_enabled || exit 0

mapfile -t _lines < <(python3 - "$STATE" "$THRESHOLD" "$REPEAT_SEC" "$WATCH" <<'PY'
import json
import subprocess
import sys
from datetime import datetime, timezone
from pathlib import Path

state_path, threshold_s, repeat_s, watch_raw = sys.argv[1:5]
threshold = int(threshold_s)
repeat_sec = int(repeat_s)
watch = [w for w in watch_raw.split() if w]
now = datetime.now(timezone.utc).timestamp()

def load_state() -> dict:
    try:
        data = json.loads(Path(state_path).read_text(encoding="utf-8"))
        return data if isinstance(data, dict) else {}
    except (OSError, json.JSONDecodeError):
        return {}

def save_state(data: dict) -> None:
    path = Path(state_path)
    path.parent.mkdir(parents=True, exist_ok=True)
    try:
        path.write_text(json.dumps(data, indent=2) + "\n", encoding="utf-8")
    except PermissionError:
        subprocess.run(
            ["sudo", "tee", str(path)],
            input=json.dumps(data, indent=2) + "\n",
            text=True,
            check=True,
            stdout=subprocess.DEVNULL,
        )
        subprocess.run(["sudo", "chmod", "664", str(path)], check=False)

def inspect(name: str) -> tuple[int, str, bool]:
    fmt = "{{.RestartCount}}|{{.State.Status}}|{{.State.Running}}"
    try:
        out = subprocess.check_output(
            ["docker", "inspect", "-f", fmt, name],
            text=True,
            stderr=subprocess.DEVNULL,
        ).strip()
    except (subprocess.CalledProcessError, FileNotFoundError):
        return -1, "missing", False
    parts = out.split("|", 2)
    if len(parts) != 3:
        return -1, "unknown", False
    try:
        restarts = int(parts[0])
    except ValueError:
        restarts = -1
    return restarts, parts[1], parts[2] == "true"

def prometheus_corrupt() -> bool:
    try:
        logs = subprocess.check_output(
            ["docker", "logs", "prometheus", "--tail", "30"],
            text=True,
            stderr=subprocess.STDOUT,
        )
    except subprocess.CalledProcessError:
        return False
    return "invalid checksum" in logs or "opening storage failed" in logs

state = load_state()
alerts: list[tuple[str, int, str]] = []
recovered: list[str] = []

for name in watch:
    restarts, status, running = inspect(name)
    if restarts < 0:
        continue
    entry = state.get(name, {})
    last_alert = float(entry.get("last_alert_at") or 0)
    last_restarts = int(entry.get("last_alert_restarts") or 0)
    bad = restarts >= threshold or status == "restarting"
    if bad:
        jump = restarts > last_restarts
        repeat = now - last_alert >= repeat_sec
        if jump or (repeat and restarts >= threshold):
            alerts.append((name, restarts, status))
            entry["last_alert_at"] = now
            entry["last_alert_restarts"] = restarts
    elif running and status == "running" and entry.get("last_alert_at"):
        recovered.append(name)
        entry.pop("last_alert_at", None)
        entry.pop("last_alert_restarts", None)
    entry["last_seen_restarts"] = restarts
    entry["last_status"] = status
    entry["checked_at"] = datetime.now(timezone.utc).isoformat()
    state[name] = entry

save_state(state)

for name, restarts, status in alerts:
    print(f"ALERT\t{name}\t{restarts}\t{status}")

for name in recovered:
    print(f"OK\t{name}")

if any(a[0] == "prometheus" for a in alerts) and prometheus_corrupt():
    print("REPAIR\tprometheus")
PY
)

for line in "${_lines[@]:-}"; do
  IFS=$'\t' read -r kind arg1 arg2 arg3 <<<"$line"
  case "$kind" in
    ALERT)
      log "uyari: ${arg1} restarts=${arg2} status=${arg3}"
      notify_container_restart_warn "$arg1" "$arg2" "$arg3" || true
      ;;
    OK)
      log "normale dondu: ${arg1}"
      notify_container_restart_ok "$arg1" || true
      ;;
    REPAIR)
      log "prometheus TSDB auto-repair"
      if REMOTE_DIR="$REMOTE_DIR" NOTIFY_REPAIR=1 bash "$SCRIPT_DIR/repair-prometheus-tsdb.sh"; then
        log "prometheus repair OK"
      else
        log "WARN prometheus repair basarisiz"
      fi
      ;;
  esac
done
