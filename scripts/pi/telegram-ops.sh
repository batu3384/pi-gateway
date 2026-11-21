#!/usr/bin/env bash
# Telegram ops — /dns /ssd /backup /recover [/recover onay]
set -euo pipefail
REMOTE_DIR="${REMOTE_DIR:-/home/${USER}/pi-gateway}"
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
STDOUT_MODE=0
if [[ "${1:-}" == "--stdout" ]]; then
  STDOUT_MODE=1
  shift
fi
CMD="${1:-}"
SUB="${2:-}"
RECOVER_PENDING="${TELEGRAM_RECOVER_PENDING:-/var/lib/pi-gateway/telegram-recover-pending}"
RECOVER_LAST="${TELEGRAM_RECOVER_LAST:-/run/pi-gateway/telegram-recover.last}"
RECOVER_COOLDOWN_SEC="${TELEGRAM_RECOVER_COOLDOWN_SEC:-300}"
RECOVER_CONFIRM_SEC="${TELEGRAM_RECOVER_CONFIRM_SEC:-60}"
# shellcheck source=../lib/env-file.sh
source "$SCRIPT_DIR/../lib/env-file.sh"
read_remote_dotenv || { echo "[telegram-ops] HATA: .env" >&2; exit 1; }
# shellcheck source=../lib/notify.sh
source "$SCRIPT_DIR/../lib/notify.sh"
log() { echo "[telegram-ops] $*"; }

if [[ "$STDOUT_MODE" -eq 0 ]]; then
  notify_enabled || { log "TELEGRAM eksik"; exit 1; }
fi
[[ -n "$CMD" ]] || { log "Kullanim: $0 [--stdout] dns|ssd|backup|recover [onay]"; exit 1; }

_send() {
  local text="$1"
  if [[ "$STDOUT_MODE" -eq 1 ]]; then
    python3 - "$text" <<'PY'
import html, re, sys
raw = sys.argv[1]
plain = re.sub(r"</?(?:b|i|code|pre|strong|em)>", "", raw)
print(html.unescape(plain))
PY
    return 0
  fi
  notify_send_message "$text" "HTML"
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
    "restic/restic@sha256:136600b6ff6843d61d355f7f71f460a166429f35de6fd11b568fece3c9a4d510",
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

_recover_lockdir() {
  if mkdir -p /run/pi-gateway 2>/dev/null && [[ -w /run/pi-gateway ]]; then
    echo "/run/pi-gateway/telegram-recover.lock"
  else
    echo "/tmp/pi-gateway-telegram-recover.lock"
  fi
}

_recover_lock() {
  local lockdir
  lockdir="$(_recover_lockdir)"
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
  rmdir "$(_recover_lockdir)" 2>/dev/null || true
}

_cmd_recover() {
  local confirm="${1:-}"
  local repair="${REMOTE_DIR}/scripts/pi/repair-post-ssd-recovery.sh"
  [[ -x "$repair" ]] || { _send $'<b>Kurtarma</b>\n\nrepair script yok.'; return 1; }

  if [[ "$confirm" != "onay" && "$confirm" != "confirm" ]]; then
    mkdir -p "$(dirname "$RECOVER_PENDING")" 2>/dev/null || true
    if ! date +%s >"$RECOVER_PENDING" 2>/dev/null; then
      RECOVER_PENDING="/run/pi-gateway/telegram-recover-pending"
      mkdir -p /run/pi-gateway 2>/dev/null || true
      date +%s >"$RECOVER_PENDING"
    fi
    _send "<b>🛠️ SSD Kurtarma</b>

Docker geçici olarak durdurulur, dosya sistemi / restic onarımı ve yedek doğrulaması çalıştırılır.

Onay için <b>60 sn</b> içinde gönderin: <code>/recover onay</code>"
    return 0
  fi

  local pending_ts now last_ts
  if [[ ! -f "$RECOVER_PENDING" && -f "/run/pi-gateway/telegram-recover-pending" ]]; then
    RECOVER_PENDING="/run/pi-gateway/telegram-recover-pending"
  fi
  pending_ts="$(cat "$RECOVER_PENDING" 2>/dev/null || echo 0)"
  now="$(date +%s)"
  if (( now - pending_ts > RECOVER_CONFIRM_SEC )); then
    _send $'<b>🛠️ Kurtarma</b>\n\nOnay süresi doldu. Önce <code>/recover</code> gönderin.'
    return 1
  fi
  rm -f "$RECOVER_PENDING" 2>/dev/null || true

  last_ts="$(cat "$RECOVER_LAST" 2>/dev/null || echo 0)"
  if [[ "$last_ts" =~ ^[0-9]+$ ]] && (( now - last_ts < RECOVER_COOLDOWN_SEC )); then
    _send "<b>Kurtarma</b>

Yakın zamanda çalıştı (${RECOVER_COOLDOWN_SEC}s bekle)."
    return 1
  fi

  if ! _recover_lock; then
    _send "<b>Kurtarma</b>

Kurtarma şu an çalışıyor."
    return 1
  fi
  date +%s >"$RECOVER_LAST" 2>/dev/null || true

  if [[ "$STDOUT_MODE" -eq 0 ]]; then
    _send $'<b>SSD kurtarma</b>\n\nYazılımsal onarım başlatıldı…'
  fi
  local rc=0
  export REMOTE_DIR
  if ! mountpoint -q /mnt/ssd 2>/dev/null || [[ -f /run/pi-gateway/storage-degraded ]]; then
    if [[ -x "${REMOTE_DIR}/scripts/pi/ssd-health.sh" ]]; then
      SSD_HEALTH_AUTO=true bash "${REMOTE_DIR}/scripts/pi/ssd-health.sh" >/dev/null 2>&1 || rc=1
    fi
    if [[ -x "${REMOTE_DIR}/scripts/pi/recover-stack.sh" ]]; then
      bash "${REMOTE_DIR}/scripts/pi/recover-stack.sh" >/dev/null 2>&1 || rc=1
    fi
  fi
  if REPAIR_DEFER_OPENBOT_RESTART=true bash "$repair" >/dev/null 2>&1 && [[ "$rc" -eq 0 ]]; then
    _send $'<b>SSD kurtarma</b>\n\n✅ Tamamlandı.'
    _recover_unlock
    return 0
  fi
  _send $'<b>SSD kurtarma</b>\n\n⚠️ Kısmi — journalctl bak.'
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
if [[ "$STDOUT_MODE" -eq 0 ]]; then
  log "OK $CMD"
fi
