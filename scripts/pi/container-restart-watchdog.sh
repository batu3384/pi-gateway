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
WINDOW_SEC="${CONTAINER_RESTART_WINDOW_SEC:-900}"
STABLE_SEC="${CONTAINER_RESTART_STABLE_SEC:-600}"
STATE="${CONTAINER_WATCH_STATE_PATH:-/var/lib/pi-gateway/container-watch-state.json}"
WATCH="${CONTAINER_WATCH_LIST:-prometheus grafana n8n adguard unbound caddy crowdsec netalertx}"

log() { echo "[container-watch] $*"; }

if [[ "${1:-}" == "--self-check" ]]; then
  [[ "$THRESHOLD" =~ ^[0-9]+$ ]] || exit 1
  [[ "$WINDOW_SEC" =~ ^[0-9]+$ ]] || exit 1
  grep -q 'notify_container_restart' "$SCRIPT_DIR/../lib/notify.sh" || exit 1
  python3 - "$THRESHOLD" "$WINDOW_SEC" <<'PY' || exit 1
import sys
threshold, window = int(sys.argv[1]), int(sys.argv[2])
now = 1_000_000.0
events = [{"at": now - 60, "delta": 1}, {"at": now - 120, "delta": 1}]
total = sum(e["delta"] for e in events if now - e["at"] < window)
assert total < threshold, "tek deploy spike alarm olmamali"
events.append({"at": now - 30, "delta": 2})
total = sum(e["delta"] for e in events if now - e["at"] < window)
assert total >= threshold, "gercek dongu alarm olmali"
PY
  log "self-check OK"
  exit 0
fi

notify_enabled || exit 0

mapfile -t _lines < <(python3 - "$STATE" "$THRESHOLD" "$REPEAT_SEC" "$WINDOW_SEC" "$STABLE_SEC" "$WATCH" <<'PY'
import json
import subprocess
import sys
from datetime import datetime, timezone
from pathlib import Path

state_path, threshold_s, repeat_s, window_s, stable_s, watch_raw = sys.argv[1:7]
threshold = int(threshold_s)
repeat_sec = int(repeat_s)
window_sec = int(window_s)
stable_sec = int(stable_s)
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

def prometheus_ready() -> bool:
    try:
        if subprocess.run(
            ["curl", "-fsS", "--max-time", "3", "http://127.0.0.1:9090/-/ready"],
            stdout=subprocess.DEVNULL,
            stderr=subprocess.DEVNULL,
        ).returncode != 0:
            return False
        out = subprocess.check_output(
            ["docker", "ps", "--format", "{{.Names}}"],
            text=True,
            stderr=subprocess.DEVNULL,
        )
    except (subprocess.CalledProcessError, FileNotFoundError):
        return False
    return any(line.strip() == "prometheus" for line in out.splitlines())


def prometheus_needs_repair() -> bool:
    try:
        logs = subprocess.check_output(
            ["docker", "logs", "prometheus", "--tail", "50"],
            text=True,
            stderr=subprocess.STDOUT,
        )
    except subprocess.CalledProcessError:
        return False
    if "invalid checksum" in logs or "opening storage failed" in logs:
        return True
    if not prometheus_ready():
        return "WAL truncation" in logs and "compaction failed" in logs
    return False


def prune_events(events: list, cutoff: float) -> list[dict]:
    kept: list[dict] = []
    for raw in events:
        if not isinstance(raw, dict):
            continue
        try:
            at = float(raw.get("at", 0))
            delta = int(raw.get("delta", 0))
        except (TypeError, ValueError):
            continue
        if delta <= 0 or at < cutoff:
            continue
        kept.append({"at": at, "delta": delta})
    return kept


state = load_state()
alerts: list[tuple[str, int, str, int]] = []
recovered: list[str] = []

for name in watch:
    restarts, status, running = inspect(name)
    if restarts < 0:
        continue
    entry = state.get(name, {})
    if not isinstance(entry, dict):
        entry = {}

    last_seen = int(entry.get("last_seen_restarts", restarts))
    events = prune_events(entry.get("restart_events") or [], now - window_sec)
    if restarts > last_seen:
        events.append({"at": now, "delta": restarts - last_seen})

    window_total = sum(e["delta"] for e in events)
    restarting = status == "restarting"
    bad = restarting or window_total >= threshold
    was_alerting = bool(entry.get("alerting"))
    last_alert = float(entry.get("last_alert_at") or 0)

    # Eski kümülatif alarm state — pencere sifirsa temizle
    if entry.get("last_alert_at") and not was_alerting and window_total == 0 and not restarting:
        entry.pop("last_alert_at", None)
        entry.pop("last_alert_restarts", None)

    if bad:
        should_alert = False
        if not was_alerting:
            should_alert = True
        elif window_total > int(entry.get("last_alert_window_total", 0)):
            should_alert = True
        elif now - last_alert >= repeat_sec:
            should_alert = True
        if should_alert:
            alerts.append((name, window_total, status, restarts))
            entry["alerting"] = True
            entry["last_alert_at"] = now
            entry["last_alert_window_total"] = window_total
            entry.pop("stable_since", None)
    elif was_alerting and running and status == "running":
        stable_since = float(entry.get("stable_since") or 0)
        if not stable_since:
            entry["stable_since"] = now
        elif now - stable_since >= stable_sec:
            recovered.append(name)
            entry["alerting"] = False
            entry.pop("last_alert_at", None)
            entry.pop("last_alert_window_total", None)
            entry.pop("stable_since", None)
    else:
        entry.pop("stable_since", None)

    entry["restart_events"] = events
    entry["last_seen_restarts"] = restarts
    entry["last_status"] = status
    entry["checked_at"] = datetime.now(timezone.utc).isoformat()
    state[name] = entry

save_state(state)

for name, window_total, status, lifetime in alerts:
    print(f"ALERT\t{name}\t{window_total}\t{status}\t{lifetime}")

for name in recovered:
    print(f"OK\t{name}")

if any(a[0] == "prometheus" for a in alerts) and prometheus_needs_repair():
    print("REPAIR\tprometheus")

# Prometheus ayakta degil + TSDB — restart alarmi olmasa da repair dene
if not any(a[0] == "prometheus" for a in alerts) and prometheus_needs_repair():
    print("REPAIR\tprometheus")
PY
)

for line in "${_lines[@]:-}"; do
  IFS=$'\t' read -r kind arg1 arg2 arg3 arg4 <<<"$line"
  case "$kind" in
    ALERT)
      log "uyari: ${arg1} window=${arg2} lifetime=${arg4:-?} status=${arg3}"
      notify_container_restart_warn "$arg1" "$arg2" "$arg3" "${arg4:-}" || true
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
