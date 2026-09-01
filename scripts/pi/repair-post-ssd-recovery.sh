#!/usr/bin/env bash
# SSD yazilim kurtarma sonrasi: docker net + restic + izinler + backup.
set -euo pipefail
REMOTE_DIR="${REMOTE_DIR:-/home/${USER}/pi-gateway}"
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=../lib/env-file.sh
source "$SCRIPT_DIR/../lib/env-file.sh"
read_remote_dotenv || { echo "[repair-post-ssd] HATA: .env" >&2; exit 1; }
# shellcheck source=../lib/stack-health.sh
source "$SCRIPT_DIR/../lib/stack-health.sh"
log() { echo "[repair-post-ssd] $*"; }

if ! ssd_mount_healthy; then
  log "HATA: SSD mount sagliksiz — once ssd-health/hotplug"
  exit 1
fi

REMOTE_DIR="$REMOTE_DIR" bash "$SCRIPT_DIR/repair-docker-network-store.sh" \
  || log "WARN: docker network repair"
REMOTE_DIR="$REMOTE_DIR" bash "$SCRIPT_DIR/fix-config-perms.sh" 2>/dev/null \
  || log "WARN: config perms"

if [[ "${ENABLE_RESTIC:-true}" == "true" ]]; then
  REMOTE_DIR="$REMOTE_DIR" bash "$SCRIPT_DIR/restic-repair.sh" \
    || log "WARN: restic repair"
  if REMOTE_DIR="$REMOTE_DIR" bash "$SCRIPT_DIR/restic-backup.sh"; then
    log "restic backup OK"
  else
    log "WARN: restic backup"
  fi
fi

if [[ -d "$REMOTE_DIR/compose" ]]; then
  (cd "$REMOTE_DIR/compose" && docker compose --env-file ../.env up -d crowdsec) 2>/dev/null \
    || log "WARN: crowdsec up"
fi
# shellcheck source=../lib/reset-gateway-units.sh
source "$SCRIPT_DIR/../lib/reset-gateway-units.sh"
reset_pi_gateway_failed_units 2>/dev/null || true
# shellcheck source=../lib/notify.sh
source "$SCRIPT_DIR/../lib/notify.sh"
_incident="$(python3 - <<'PY' 2>/dev/null || true
import json
from pathlib import Path
st = {}
p = Path("/var/lib/pi-gateway/ssd-usb-metrics-state.json")
if p.is_file():
    try:
        st = json.loads(p.read_text(encoding="utf-8"))
    except Exception:
        pass
parts = []
if st:
    parts.append(f"CRC {st.get('crc', '?')} (Δ{st.get('crc_delta', 0)})")
    parts.append(f"reset24h={st.get('usb_resets_24h', 0)} io24h={st.get('io_errors_24h', 0)}")
parts.append("docker net + restic repair + backup")
print("; ".join(parts) if parts else "post-ssd repair OK")
PY
)"
notify_ssd_post_recovery "$_incident" 2>/dev/null || true
_state_json="/var/lib/pi-gateway/state.json"
python3 - "$_incident" "$_state_json" <<'PY' 2>/dev/null || true
import json, os, subprocess, sys, time
from pathlib import Path
detail, path = sys.argv[1], Path(sys.argv[2])
data = {}
if path.is_file():
    try:
        data = json.loads(path.read_text(encoding="utf-8"))
    except Exception:
        data = {}
data["last_ssd_incident"] = {"ts": time.strftime("%Y-%m-%dT%H:%M:%S%z"), "detail": detail}
path.parent.mkdir(parents=True, exist_ok=True)
tmp = path.with_suffix(".tmp")
tmp.write_text(json.dumps(data, indent=2) + "\n", encoding="utf-8")
if os.geteuid() == 0:
    tmp.replace(path)
else:
    subprocess.run(["sudo", "install", "-m", "644", str(tmp), str(path)], check=False)
    tmp.unlink(missing_ok=True)
PY
log "Tamamlandi"
