#!/usr/bin/env bash
# Telegram ops — /dns /ssd /backup /recover [/recover onay]
set -euo pipefail
REMOTE_DIR="${REMOTE_DIR:-/home/${USER}/pi-gateway}"
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
CMD="${1:-}"
SUB="${2:-}"
RECOVER_PENDING="${TELEGRAM_RECOVER_PENDING:-/var/lib/pi-gateway/telegram-recover-pending}"
RECOVER_COOLDOWN_SEC="${TELEGRAM_RECOVER_COOLDOWN_SEC:-300}"
RECOVER_CONFIRM_SEC="${TELEGRAM_RECOVER_CONFIRM_SEC:-60}"
# shellcheck source=../lib/env-file.sh
source "$SCRIPT_DIR/../lib/env-file.sh"
read_remote_dotenv || { echo "[telegram-ops] HATA: .env" >&2; exit 1; }
load_telegram_from_hermes || true
# shellcheck source=../lib/notify.sh
source "$SCRIPT_DIR/../lib/notify.sh"
log() { echo "[telegram-ops] $*"; }

notify_enabled || { log "TELEGRAM eksik"; exit 1; }
[[ -n "$CMD" ]] || { log "Kullanim: $0 dns|ssd|backup|recover [onay]"; exit 1; }

API="https://api.telegram.org/bot${TELEGRAM_BOT_TOKEN}"
_send() {
  local text="$1"
  curl -fsS -X POST "${API}/sendMessage" \
    --data-urlencode "chat_id=${TELEGRAM_CHAT_ID}" \
    --data-urlencode "parse_mode=HTML" \
    --data-urlencode "text=${text}" \
    -d "disable_web_page_preview=true" >/dev/null
}

_cmd_dns() {
  local audit="${REMOTE_DIR}/scripts/pi/audit-dns-coverage.sh"
  local state="${ADGUARD_DNS_COVERAGE_STATE_PATH:-/var/lib/pi-gateway/dns-coverage-state.json}"
  if [[ -x "$audit" ]]; then
    ADGUARD_COVERAGE_AUDIT_MODE=warn REMOTE_DIR="$REMOTE_DIR" bash "$audit" >/tmp/pi-gw-dns-ops.log 2>&1 || true
  fi
  python3 - "$state" <<'PY'
import html, json, sys
from pathlib import Path
path = Path(sys.argv[1])
st = {}
if path.is_file():
    try:
        st = json.loads(path.read_text(encoding="utf-8"))
    except (OSError, json.JSONDecodeError):
        pass
pct = st.get("coverage_percent", -1)
active = st.get("active_devices", -1)
using = st.get("using_pi_dns", -1)
status = st.get("status", "unknown")
lines = ["<b>DNS kapsam</b>"]
if pct >= 0:
    lines.append(f"Doğrulanan: <b>{using}/{active}</b> (%{pct}) — durum <code>{html.escape(str(status))}</code>")
else:
    lines.append("Kanıt yok — audit henüz çalışmadı.")
lines.append("")
lines.append("<i>Bypass:</i> make audit-dns · <i>Kart:</i> /menu")
print("\n".join(lines))
PY
}

_cmd_ssd() {
  python3 - <<'PY'
import html, json, subprocess
from pathlib import Path

def ok_mount() -> bool:
    try:
        subprocess.run(["mountpoint", "-q", "/mnt/ssd"], check=True, timeout=3)
        return True
    except (subprocess.CalledProcessError, OSError, ValueError):
        return False

st = {}
p = Path("/var/lib/pi-gateway/ssd-usb-metrics-state.json")
if p.is_file():
    try:
        st = json.loads(p.read_text(encoding="utf-8"))
    except (OSError, json.JSONDecodeError):
        pass
lines = ["<b>SSD / USB</b>", f"Mount: <code>{'OK' if ok_mount() else 'YOK'}</code>"]
if st:
    if st.get("crc") is not None:
        lines.append(f"CRC: <code>{st['crc']}</code> (Δ{st.get('crc_delta', 0)})")
    lines.append(
        f"24s: reset <code>{st.get('usb_resets_24h', 0)}</code> · I/O <code>{st.get('io_errors_24h', 0)}</code>"
    )
lines.append("")
lines.append("<i>Kurtarma:</i> /recover → /recover onay")
print("\n".join(lines))
PY
}

_cmd_backup() {
  export RESTIC_OFFSITE_ENABLED RESTIC_REPOSITORY RESTIC_PASSWORD RESTIC_IMAGE
  python3 - <<'PY'
import html, os, subprocess, tempfile, time
from pathlib import Path

def age_days(path: str) -> int:
    p = Path(path)
    if not p.is_file():
        return -1
    return int((time.time() - p.stat().st_mtime) // 86400)

offsite = age_days("/var/lib/pi-gateway/last-offsite-backup")
cloud = age_days("/var/lib/pi-gateway/last-restic-offsite-copy")
lines = ["<b>Yedek</b>"]
lines.append(f"Mac offsite: <code>{offsite if offsite >= 0 else 'yok'} gün</code>")
if os.environ.get("RESTIC_OFFSITE_ENABLED", "false").lower() == "true":
    lines.append(f"B2/R2: <code>{cloud if cloud >= 0 else 'yok'} gün</code>")
else:
    lines.append("B2/R2: <code>kapalı</code>")
repo = os.environ.get("RESTIC_REPOSITORY", "/mnt/ssd/pi-gateway-data/backups/restic")
pwd = os.environ.get("RESTIC_PASSWORD", "")
image = os.environ.get(
    "RESTIC_IMAGE",
    "restic/restic@sha256:8f5a62b422a2cb1277ea0dd6e826fe1acf649e5b9f02d60e5268d5fd1976255a",
)
if pwd and Path(repo).is_dir():
    env_fd, env_path = tempfile.mkstemp(prefix="restic-env-", text=True)
    try:
        with os.fdopen(env_fd, "w", encoding="utf-8") as fh:
            fh.write(f"RESTIC_PASSWORD={pwd}\n")
        out = subprocess.check_output(
            [
                "docker", "run", "--rm", "--network", "none",
                "--env-file", env_path,
                "-e", "RESTIC_REPOSITORY=local:/repo",
                "-v", f"{repo}:/repo:ro",
                image, "snapshots", "--last",
            ],
            text=True, timeout=30, stderr=subprocess.DEVNULL,
        ).strip().splitlines()
        if out:
            lines.append(html.escape(out[-1][:180]))
    except (subprocess.SubprocessError, OSError, ValueError):
        pass
    finally:
        try:
            os.unlink(env_path)
        except OSError:
            pass
lines.append("")
lines.append("<i>Mac:</i> <code>make backup-pull</code>")
print("\n".join(lines))
PY
}

_recover_lock() {
  local lockdir="/run/pi-gateway/telegram-recover.lock"
  mkdir -p /run/pi-gateway 2>/dev/null || true
  if mkdir "$lockdir" 2>/dev/null; then
    return 0
  fi
  local mtime now
  mtime="$(stat -c %Y "$lockdir" 2>/dev/null || echo 0)"
  now="$(date +%s)"
  if (( now - mtime > RECOVER_COOLDOWN_SEC )); then
    rmdir "$lockdir" 2>/dev/null && mkdir "$lockdir" 2>/dev/null && return 0
  fi
  return 1
}

_recover_unlock() {
  rmdir "/run/pi-gateway/telegram-recover.lock" 2>/dev/null || true
}

_cmd_recover() {
  local confirm="${1:-}"
  local repair="${REMOTE_DIR}/scripts/pi/repair-post-ssd-recovery.sh"
  [[ -x "$repair" ]] || { _send "<b>Kurtarma</b>\n\nrepair script yok."; return 1; }

  if [[ "$confirm" != "onay" && "$confirm" != "confirm" ]]; then
    mkdir -p "$(dirname "$RECOVER_PENDING")" 2>/dev/null || true
    date +%s >"$RECOVER_PENDING" 2>/dev/null || true
    _send "<b>SSD kurtarma</b>

Docker durur, restic onarımı ve yedek çalışır.

Onay için <b>60 sn</b> içinde: <code>/recover onay</code>"
    return 0
  fi

  local pending_ts now
  pending_ts="$(cat "$RECOVER_PENDING" 2>/dev/null || echo 0)"
  now="$(date +%s)"
  if (( now - pending_ts > RECOVER_CONFIRM_SEC )); then
    _send "<b>Kurtarma</b>\n\nOnay süresi doldu. Önce <code>/recover</code> gönder."
    return 1
  fi
  rm -f "$RECOVER_PENDING" 2>/dev/null || true

  if ! _recover_lock; then
    _send "<b>Kurtarma</b>\n\nBaşka kurtarma yakın zamanda çalıştı (${RECOVER_COOLDOWN_SEC}s bekle)."
    return 1
  fi

  _send "<b>SSD kurtarma</b>\n\nYazılımsal onarım başlatıldı…"
  if REMOTE_DIR="$REMOTE_DIR" bash "$repair"; then
    _send "<b>SSD kurtarma</b>\n\n✅ Tamamlandı."
    _recover_unlock
    return 0
  fi
  _send "<b>SSD kurtarma</b>\n\n⚠️ Kısmi — journalctl bak."
  _recover_unlock
  return 1
}

case "$CMD" in
  dns) _send "$(_cmd_dns)" ;;
  ssd) _send "$(_cmd_ssd)" ;;
  backup) _send "$(_cmd_backup)" ;;
  recover) _cmd_recover "$SUB" ;;
  *)
    log "Bilinmeyen: $CMD"
    exit 1
    ;;
esac
log "OK $CMD"
