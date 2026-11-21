#!/usr/bin/env bash
# Antigravity/OpenBot filo onarımı — rutin delivery_start_failed / Gemini version.
set -euo pipefail
REMOTE_DIR="${REMOTE_DIR:-/home/${USER}/pi-gateway}"
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=../lib/openbot-paths.sh
source "${SCRIPT_DIR}/../lib/openbot-paths.sh"
# shellcheck source=../lib/env-file.sh
source "${SCRIPT_DIR}/../lib/env-file.sh"
read_remote_dotenv || true

log() { echo "[heal-openbot-fleet] $*"; }

AGY_CANON_VER="${OPENBOT_ANTIGRAVITY_VERSION:-1.5.12}"
PR="$(openbot_state_dir)/provider-runtimes/antigravity/linux-arm64"
ENV_FILE="/opt/OpenBot/hosted/openbot.env"
DEST_AGY="${PR}/${AGY_CANON_VER}/bin/antigravity"
need_repair=0

prune_legacy_agy() {
  [[ -d "$PR" ]] || return 0
  local d ver
  for d in "$PR"/*/; do
    [[ -d "$d" ]] || continue
    ver="$(basename "$d")"
    [[ "$ver" == "$AGY_CANON_VER" ]] && continue
    log "eski antigravity kaldırılıyor: $ver"
    rm -rf "$d"
    need_repair=1
  done
}

agy_ok() {
  local agy="$1"
  [[ -x "$agy" ]] || return 1
  "$agy" --version >/dev/null 2>&1
}

DROP_PROVIDER="/etc/systemd/system/openbot.service.d/provider-paths.conf"
ensure_hosted_env() {
  if [[ ! -f "$ENV_FILE" ]] || ! grep -q "OPENBOT_ANTIGRAVITY_PATH=" "$ENV_FILE" 2>/dev/null; then
    need_repair=1
    return
  fi
  if [[ ! -f "$DROP_PROVIDER" ]] || ! grep -q "OPENBOT_ANTIGRAVITY_PATH=${DEST_AGY}" "$DROP_PROVIDER" 2>/dev/null; then
    need_repair=1
    return
  fi
  local cur
  cur="$(grep '^OPENBOT_ANTIGRAVITY_PATH=' "$ENV_FILE" | cut -d= -f2-)"
  if [[ "$cur" != "$DEST_AGY" ]] || ! agy_ok "$cur"; then
    need_repair=1
  fi
}

patch_agents_antigravity_model() {
  local db
  db="$(openbot_db_path)"
  [[ -f "$db" ]] || return 0
  python3 - "$db" <<'PY'
import json, sqlite3, sys
db = sys.argv[1]
con = sqlite3.connect(db)
want = "gemini-3.8-flash"
for agent_id, blob in con.execute("select agent_id, agent_json from projection_agents"):
    a = json.loads(blob)
    if a.get("provider") != "antigravity":
        continue
    ch = False
    if a.get("model") != want:
        a["model"] = want
        ch = True
    if a.get("reasoningEffort") == "high":
        a["reasoningEffort"] = "medium"
        ch = True
    if a.get("notifications") is not True:
        a["notifications"] = True
        ch = True
    if a.get("allowAutomation") is not True:
        a["allowAutomation"] = True
        ch = True
    if ch:
        con.execute(
            "update projection_agents set agent_json=?, model=? where agent_id=?",
            (json.dumps(a, ensure_ascii=False, separators=(",", ":")), want, agent_id),
        )
        print("agent", a.get("name"), "→", want, a.get("reasoningEffort"))
con.commit()
PY
}

prune_legacy_agy
ensure_hosted_env

if [[ "$need_repair" -eq 1 ]] || ! agy_ok "$DEST_AGY" 2>/dev/null; then
  log "provider runtime tam onarım"
  bash "${SCRIPT_DIR}/repair-openbot-provider-runtimes.sh"
  need_repair=0
else
  log "antigravity yolu OK — tam repair atlandı"
  if ! systemctl is-active --quiet openbot.service; then
    sudo systemctl start openbot.service
  fi
fi

# Canlı WAL DB'ye openbot çalışırken doğrudan yazma — önce read-only kontrol, değişiklik gerekirse durdurup uygula
agents_need_patch() {
  local db
  db="$(openbot_db_path)"
  [[ -f "$db" ]] || return 1
  python3 - "$db" <<'PY'
import json, sqlite3, sys
con = sqlite3.connect(f"file:{sys.argv[1]}?mode=ro", uri=True)
for _, blob in con.execute("select agent_id, agent_json from projection_agents"):
    a = json.loads(blob)
    if a.get("provider") != "antigravity":
        continue
    if a.get("model") != "gemini-3.8-flash" or a.get("reasoningEffort") == "high" or a.get("notifications") is not True or a.get("allowAutomation") is not True:
        sys.exit(0)
sys.exit(1)
PY
}

if agents_need_patch; then
  log "openbot durduruluyor (agent DB yaması — canlı WAL yazımı yasak)"
  sudo systemctl stop openbot.service 2>/dev/null || true
  agent_patch="$(patch_agents_antigravity_model || true)"
  [[ -n "$agent_patch" ]] && printf '%s\n' "$agent_patch"
  need_repair=1
fi

if [[ "$need_repair" -eq 1 ]] || ! systemctl is-active --quiet openbot.service; then
  log "OpenBot yeniden yükleme (onarım veya servis kapalı)"
  sudo systemctl restart openbot.service
else
  log "runtime sağlam — openbot restart yok"
fi
_auto_wait=0
while :; do
  if systemctl is-active --quiet openbot.service; then
    auto="$(openbot_automation_dir)"
    if [[ -f "${auto}/url" && -f "${auto}/headers" ]]; then
      log "automation hazır (${_auto_wait}s)"
      break
    fi
  fi
  ((_auto_wait++ >= 90)) && {
    log "HATA: 180s içinde openbot/automation hazır olmadı"
    systemctl is-active openbot.service || true
    exit 1
  }
  if ((_auto_wait % 5 == 0)); then
    log "bekleniyor… openbot=$(systemctl is-active openbot.service 2>/dev/null || echo ?) ${_auto_wait}s"
  fi
  sleep 2
done

if [[ "${OPENBOT_HEAL_UPDATE:-}" == "true" ]] && command -v openbot >/dev/null 2>&1; then
  if openbot status 2>/dev/null | grep -q 'is ready to install'; then
    log "openbot update (OPENBOT_HEAL_UPDATE=true)"
    sudo openbot update || log "WARN: openbot update başarısız"
    sudo systemctl restart openbot.service
    sleep 10
  fi
fi

VERIFY="${SCRIPT_DIR}/verify-openbot-fleet.sh"
[[ -x "$VERIFY" ]] || chmod +x "$VERIFY"
if ! REMOTE_DIR="$REMOTE_DIR" bash "$VERIFY"; then
  log "HATA: verify başarısız"
  exit 1
fi

if [[ "${OPENBOT_HEAL_PROBE_AGENTS:-false}" == "true" && "${OPENBOT_HEAL_QUICK:-}" != "true" ]]; then
  log "Antigravity smoke (Falcon rutin sırası değil — kısa mesaj)"
  if REMOTE_DIR="$REMOTE_DIR" OPENBOT_JARVIS_WAIT_DELIVERY=true \
    JARVIS_AGENT_NAME=Falcon OPENBOT_ALERT_WAIT_SEC=180 \
    bash "${SCRIPT_DIR}/jarvis-send.sh" --wait --timeout 180 --id "pi-gateway:heal-falcon" \
    "Heimdall · durum

Onarım sonrası kısa test. Tek cümle: Falcon provider canlı."; then
    log "Falcon smoke OK"
  else
    log "WARN: Falcon smoke başarısız — journalctl -u openbot.service"
    exit 1
  fi
fi

log "Filo onarımı tamam"