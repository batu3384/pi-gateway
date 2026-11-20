#!/usr/bin/env bash
# Heimdall filo + uyarı yolu smoke (Pi üzerinde).
set -euo pipefail
REMOTE_DIR="${REMOTE_DIR:-/home/${USER}/pi-gateway}"
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=../lib/openbot-paths.sh
source "${SCRIPT_DIR}/../lib/openbot-paths.sh"
# shellcheck source=../lib/env-file.sh
source "${SCRIPT_DIR}/../lib/env-file.sh"
read_remote_dotenv || true

failures=()
ok() { echo "[fleet-verify] OK $*"; }
bad() { failures+=("$1"); echo "[fleet-verify] FAIL $1" >&2; }

need() {
  command -v "$1" >/dev/null 2>&1 || bad "komut yok: $1"
}

need systemctl
need python3
need curl

systemctl is-active --quiet openbot.service && ok "openbot.service" || bad "openbot.service aktif değil"

agy_root="$(openbot_state_dir)/provider-runtimes/antigravity/linux-arm64"
if [[ -d "$agy_root" ]]; then
  for legacy in 1.5.4 1.5.5; do
    [[ -x "${agy_root}/${legacy}/bin/antigravity" ]] && bad "antigravity ${legacy} kaldır (repair-openbot-provider-runtimes)"
  done
  agy="$(grep -E '^OPENBOT_ANTIGRAVITY_PATH=' /opt/OpenBot/hosted/openbot.env 2>/dev/null | cut -d= -f2-)"
  [[ -x "$agy" ]] && ok "antigravity ${agy##*/}" || bad "OPENBOT_ANTIGRAVITY_PATH eksik"
  if "$agy" --version >/dev/null 2>&1; then
    ok "antigravity --version"
  else
    bad "antigravity --version başarısız"
  fi
fi

auto_dir="$(openbot_automation_dir)"
_auto_wait=0
while [[ ! -f "${auto_dir}/url" || ! -f "${auto_dir}/headers" ]]; do
  ((_auto_wait++ >= 30)) && break
  sleep 2
done
[[ -f "${auto_dir}/url" && -f "${auto_dir}/headers" ]] && ok "automation dosyaları" \
  || bad "automation yok ($auto_dir) — openbot restart sonrası ~1 dk bekleyin"

db="$(openbot_db_path)"
[[ -f "$db" ]] || bad "openbot.db yok"

python3 - "$db" <<'PY' || bad "ajan doğrulama"
import json, sqlite3, sys
db = sys.argv[1]
want = {"Jarvis", "Falcon", "Spider", "Ultron", "Cipher", "Iron"}
con = sqlite3.connect(f"file:{db}?mode=ro", uri=True)
names = []
for blob, in con.execute("select agent_json from projection_agents"):
    a = json.loads(blob)
    names.append(a.get("name"))
    if a.get("name") not in want:
        continue
    if not a.get("allowAutomation"):
        print(f"FAIL {a['name']}: allowAutomation kapalı", file=sys.stderr)
        sys.exit(1)
    if a.get("notifications") is False:
        print(f"FAIL {a['name']}: notifications kapalı", file=sys.stderr)
        sys.exit(1)
missing = want - set(names)
if missing:
    print(f"FAIL eksik ajan: {missing}", file=sys.stderr)
    sys.exit(1)
routines = con.execute("select count(*) from projection_agent_routines where active=1").fetchone()[0]
if routines < 8:
    print(f"FAIL aktif rutin {routines} < 8", file=sys.stderr)
    sys.exit(1)
jarvis = [json.loads(b) for b, in con.execute("select agent_json from projection_agents") if json.loads(b).get("name")=="Jarvis"][0]
if jarvis.get("provider") != "opencode":
    print("FAIL Jarvis provider opencode değil", file=sys.stderr)
    sys.exit(1)
print(f"OK agents={len(want)} routines={routines} jarvis={jarvis.get('model')}")
PY

FLEET="${OPENBOT_FLEET_ROOT:-/mnt/ssd/openbot-native/fleet}"
for agent in jarvis falcon spider ultron cipher iron; do
  [[ -e "${FLEET}/${agent}" ]] && ok "workspace $agent" || bad "workspace yok: $agent"
done

case "${NOTIFY_BACKEND:-openbot}" in
  openbot|both) ok "NOTIFY_BACKEND=${NOTIFY_BACKEND:-openbot}" ;;
  *) bad "NOTIFY_BACKEND=${NOTIFY_BACKEND:-?}" ;;
esac
[[ "${OPENBOT_JARVIS_AUTOMATION:-}" == "true" ]] && ok "OPENBOT_JARVIS_AUTOMATION" \
  || bad "OPENBOT_JARVIS_AUTOMATION kapalı"

systemctl is-enabled --quiet pi-fleet-watchdog.timer 2>/dev/null && ok "watchdog timer" \
  || bad "pi-fleet-watchdog.timer kapalı"

if [[ "${FLEET_VERIFY_LIVE_ALERT:-}" == "true" ]]; then
  if REMOTE_DIR="$REMOTE_DIR" bash "${SCRIPT_DIR}/jarvis-send.sh" \
    --wait --timeout "${OPENBOT_ALERT_WAIT_SEC:-90}" \
  --id "pi-gateway:verify-$(date +%s)" \
    "Heimdall · durum

Filo doğrulama pingi. Yanıt: tek cümle OK."; then
    ok "jarvis-send --wait"
  else
    bad "jarvis-send --wait"
  fi
fi

if ((${#failures[@]})); then
  printf '[fleet-verify] %s hata\n' "${#failures[@]}" >&2
  exit 1
fi
echo "[fleet-verify] filo hazır"
exit 0