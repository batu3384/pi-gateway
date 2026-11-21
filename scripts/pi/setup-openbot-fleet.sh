#!/usr/bin/env bash
# OpenBot 6 ajan filosu. AdGuard / compose konteynerlerine dokunmaz.
# --files-only: DB/servis dokunmadan yalnızca AGENTS.md + skills (placeholder ikamesi dahil) senkronlar.
set -euo pipefail
FILES_ONLY=0
[[ "${1:-}" == "--files-only" ]] && FILES_ONLY=1
REMOTE_DIR="${REMOTE_DIR:-/home/${USER}/pi-gateway}"
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
if [[ -f "${SCRIPT_DIR}/../lib/env-file.sh" ]]; then
  # shellcheck source=../lib/env-file.sh
  source "${SCRIPT_DIR}/../lib/env-file.sh"
  read_remote_dotenv || true
fi
# shellcheck source=../lib/openbot-paths.sh
source "${SCRIPT_DIR}/../lib/openbot-paths.sh"

DATA_ROOT="$(openbot_data_root)"
STATE_DIR="$(openbot_state_dir)"
DB="${STATE_DIR}/openbot.db"
FLEET="${DATA_ROOT}/fleet"
STAMP="$(date +%Y%m%d-%H%M)"
BACKUP_ROOT="${OPENBOT_BACKUP_ROOT:-/mnt/ssd/pi-gateway-data/backups}"
BACKUP="${BACKUP_ROOT}/openbot_pre_6fleet_${STAMP}"

log() { echo "[openbot-fleet] $*"; }

if [[ "$FILES_ONLY" -eq 0 ]]; then
  [[ -f "$DB" ]] || { log "HATA: $DB yok"; exit 1; }

  log "yedek → $BACKUP"
  mkdir -p "$BACKUP"
  python3 - "$DB" "$BACKUP/openbot.db" <<'PY'
import sqlite3, sys
src = sqlite3.connect(sys.argv[1])
dst = sqlite3.connect(sys.argv[2])
src.backup(dst)
dst.close()
src.close()
PY
  if [[ -d "${DATA_ROOT}/OpenBot/Agents" ]]; then
    tar -C "$DATA_ROOT" -czf "$BACKUP/Agents.tgz" OpenBot/Agents
  fi
  [[ -f "${HOME}/.config/opencode/opencode.json" ]] && \
    cp -a "${HOME}/.config/opencode/opencode.json" "$BACKUP/opencode.json"
  log "yedek tamam"
else
  [[ -d "$FLEET" ]] || { log "atlandı ($FLEET yok)"; exit 0; }
fi

mkdir -p \
  "$FLEET/shared" \
  "$FLEET/jarvis" "$FLEET/falcon" "$FLEET/spider" \
  "$FLEET/ultron" "$FLEET/cipher" "$FLEET/iron"

write_shared() {
  local name="$1" owner="$2" readers="$3"
  local path="$FLEET/shared/$name"
  [[ -f "$path" ]] && return 0
  cat >"$path" <<EOF
# ${name}

Yazıcı: ${owner}
Okur: ${readers}

Henüz kayıt yok.
EOF
}

write_shared system_health.md Jarvis "kullanıcı"
write_shared tech_radar.md Falcon "Spider, Ultron"
write_shared career_pipeline.md Spider "Cipher, Iron"
write_shared culture_library.md Ultron "Cipher, Iron"
write_shared english_log.md Cipher Iron
write_shared weekly_plan.md Iron "Spider, Ultron, Cipher"

for name in jarvis falcon spider ultron cipher iron; do
  ln -sfn ../shared "$FLEET/$name/shared"
done

install_agents() {
  local name="$1" src="$2"
  install -m 0644 "$src" "$FLEET/$name/AGENTS.md"
  ln -sfn AGENTS.md "$FLEET/$name/SOUL.md"
}
install_agents jarvis "${REMOTE_DIR}/config/openbot/fleet/jarvis.md"
for name in falcon spider ultron cipher iron; do
  install_agents "$name" "${REMOTE_DIR}/config/openbot/fleet/${name}.md"
done

install_skill() {
  local agent="$1" skill="$2" src="$3"
  [[ -f "$src" ]] || return 0
  local rendered
  rendered="$(mktemp)"
  sed "s|__REMOTE_DIR__|${REMOTE_DIR}|g" "$src" >"$rendered"
  mkdir -p "$FLEET/$agent/.agents/skills/$skill" "$FLEET/$agent/.claude/skills/$skill"
  install -m 0644 "$rendered" "$FLEET/$agent/.agents/skills/$skill/SKILL.md"
  install -m 0644 "$rendered" "$FLEET/$agent/.claude/skills/$skill/SKILL.md"
  rm -f "$rendered"
}
install_skill jarvis heimdall-alert "${REMOTE_DIR}/config/openbot/fleet/skills/heimdall-alert/SKILL.md"
install_skill jarvis tavily-research "${REMOTE_DIR}/config/openbot/fleet/skills/tavily-research/SKILL.md"
install_skill falcon news-radar "${REMOTE_DIR}/config/openbot/fleet/skills/news-radar/SKILL.md"
install_skill spider career-scan "${REMOTE_DIR}/config/openbot/fleet/skills/career-scan/SKILL.md"
install_skill ultron culture-file "${REMOTE_DIR}/config/openbot/fleet/skills/culture-file/SKILL.md"
install_skill cipher english-coach "${REMOTE_DIR}/config/openbot/fleet/skills/english-coach/SKILL.md"
install_skill iron day-plan "${REMOTE_DIR}/config/openbot/fleet/skills/day-plan/SKILL.md"
for skill in dns backup ssd recover menu pi-gateway-ops; do
  install_skill jarvis "$skill" "${REMOTE_DIR}/config/openbot/fleet/skills/${skill}/SKILL.md"
done
if [[ ! -f "$FLEET/spider/profile.md" ]]; then
  install -m 0644 "${REMOTE_DIR}/config/openbot/fleet/spider-profile.md" "$FLEET/spider/profile.md"
fi
cat >"$FLEET/shared/READERS.md" <<'EOF'
# Paylaşılan dosyalar

Tek yazıcı. Başkası yalnız okur.

- system_health.md — Jarvis
- tech_radar.md — Falcon
- career_pipeline.md — Spider
- culture_library.md — Ultron
- english_log.md — Cipher
- weekly_plan.md — Iron
EOF

# Kullanılmayan eski duplicate watchdog kopyasını temizle (unit repo kopyasını çalıştırır)
rm -f "$FLEET/jarvis/pi-watchdog.sh" 2>/dev/null || true

if [[ "$FILES_ONLY" -eq 1 ]]; then
  log "filo prompt + beceri senkronu tamam ($FLEET)"
  exit 0
fi

old_ws="${DATA_ROOT}/OpenBot/Agents/agent-6d0f3e6e-047a-4ec0-9697-d093cf953716"

log "openbot durduruluyor (compose/AdGuard durmaz)"
sudo systemctl stop openbot.service

export DB FLEET DATA_ROOT
export JARVIS_OPENCODE_MODEL="${JARVIS_OPENCODE_MODEL:-zai-coding-plan/glm-5.3}"
export JARVIS_REASONING_EFFORT="${JARVIS_REASONING_EFFORT:-medium}"
python3 - <<'PY'
import json, os, sqlite3, uuid
from datetime import datetime, timezone

db = sqlite3.connect(os.environ["DB"])
fleet = os.environ["FLEET"]
now = datetime.now(timezone.utc).strftime("%Y-%m-%dT%H:%M:%S.%f")[:-3] + "Z"
ns = uuid.UUID("6d0f3e6e-047a-4ec0-9697-d093cf953716")
jarvis_model = os.environ.get("JARVIS_OPENCODE_MODEL") or "zai-coding-plan/glm-5.3"
jarvis_effort = os.environ.get("JARVIS_REASONING_EFFORT") or "medium"
gemini_model = "gemini-3.8-flash"
# OpenCode workspace modu Linux'ta başlamıyor (yalnız macOS). Kabuk yasağı SOUL'da.

specs = [
    ("Jarvis", "jarvis", "full", False, True, jarvis_effort, "#8688ff", "Sistem",
     "Pi 4B, pi-gateway ve AdGuard komutanı.", "agent-6d0f3e6e-047a-4ec0-9697-d093cf953716"),
    ("Falcon", "falcon", "full", False, False, "medium", "#e0a040", "Gündem",
     "Günlük haber ve teknoloji radarı.", None),
    ("Spider", "spider", "full", False, False, "medium", "#c45c26", "Kariyer",
     "Profil doluysa ilan tarar. Boşsa durur.", None),
    ("Ultron", "ultron", "full", False, False, "medium", "#7d5cff", "Kültür",
     "Kitap ve derin kültür dosyaları.", None),
    ("Cipher", "cipher", "full", False, False, "medium", "#3dbea5", "İngilizce",
     "Akıcılık ve profesyonel iletişim.", None),
    ("Iron", "iron", "full", False, False, "medium", "#9aa0a6", "Disiplin",
     "Günlük üç odak ve haftalık plan.", None),
]

existing = {}
for agent_id, blob in db.execute("select agent_id, agent_json from projection_agents"):
    existing[json.loads(blob).get("name")] = (agent_id, json.loads(blob))

seq = db.execute("select coalesce(max(last_event_sequence),0) from projection_agents").fetchone()[0]

for order, spec in enumerate(specs):
    name, folder, access, computer, _unused, effort, color, title, desc, fixed = spec
    prev = existing.get(name)
    agent_id = prev[0] if prev else (fixed or f"agent-{uuid.uuid5(ns, folder)}")
    thread_id = f"openbot-thread-{agent_id}"
    base = prev[1] if prev else {}
    base.update({
        "id": agent_id,
        "name": name,
        "title": title,
        "description": desc,
        "notifications": True,
        "model": jarvis_model if name == "Jarvis" else gemini_model,
        "reasoningEffort": effort,
        "threadId": thread_id,
        "workspacePath": f"{fleet}/{folder}",
        "preview": base.get("preview") or "",
        "updatedAt": now,
        "avatarSeed": f"{folder}:pi-gateway:1",
        "avatarHue": None,
        "chatColor": color,
        "avatarUrl": None,
        "provider": "opencode" if name == "Jarvis" else "antigravity",
        "access": access,
        "computerUse": computer,
        "allowAutomation": True,
    })
    if name == "Jarvis":
        base["model"] = jarvis_model
        base["provider"] = "opencode"
    blob = json.dumps(base, ensure_ascii=False, separators=(",", ":"))
    if prev:
        db.execute(
            """update projection_agents
               set thread_id=?, model=?, updated_at=?, sort_order=?, agent_json=?, last_event_sequence=?
               where agent_id=?""",
            (thread_id, base["model"], now, order, blob, seq, agent_id),
        )
    else:
        db.execute(
            """insert into projection_agents (
                 agent_id, thread_id, model, updated_at, sort_order, agent_json, last_event_sequence
               ) values (?, ?, ?, ?, ?, ?, ?)""",
            (agent_id, thread_id, base["model"], now, order, blob, seq),
        )
    row = db.execute("select 1 from projection_threads where thread_id=?", (thread_id,)).fetchone()
    if row:
        db.execute(
            "update projection_threads set agent_id=?, title=?, updated_at=? where thread_id=?",
            (agent_id, name, now, thread_id),
        )
    else:
        db.execute(
            """insert into projection_threads (
                 thread_id, agent_id, title, active_turn_id, created_at, updated_at, last_event_sequence
               ) values (?, ?, ?, null, ?, ?, ?)""",
            (thread_id, agent_id, name, now, now, seq),
        )
    print(name, agent_id, access)

db.commit()
PY

export OPENBOT_STATE_DIR="$STATE_DIR" OPENBOT_DATA_ROOT="$DATA_ROOT"
OPENBOT_FLEET_SYNC_APPLY=1 python3 "${SCRIPT_DIR}/sync-fleet-routines.py" --apply

if [[ -d "$old_ws" && ! -L "$old_ws" ]]; then
  rm -rf "$old_ws"
  ln -sfn "$FLEET/jarvis" "$old_ws"
fi

sudo systemctl start openbot.service

sudo tee /etc/systemd/system/pi-fleet-watchdog.service >/dev/null <<EOF
[Unit]
Description=Pi fleet watchdog (no LLM unless threshold)
After=docker.service network-online.target

[Service]
Type=oneshot
User=${USER}
Environment=REMOTE_DIR=${REMOTE_DIR}
Environment=OPENBOT_FLEET_ROOT=${FLEET}
ExecStart=${SCRIPT_DIR}/pi-fleet-watchdog.sh
EOF
sudo tee /etc/systemd/system/pi-fleet-watchdog.timer >/dev/null <<EOF
[Unit]
Description=Run Pi fleet watchdog every 5 minutes

[Timer]
OnBootSec=2min
OnUnitActiveSec=5min
AccuracySec=30s
Persistent=false
Unit=pi-fleet-watchdog.service

[Install]
WantedBy=timers.target
EOF

for unit in jarvis-bulletin-morning jarvis-bulletin-fx jarvis-bulletin-evening \
  jarvis-bulletin-night jarvis-fx-prepare; do
  sudo systemctl disable --now "${unit}.timer" 2>/dev/null || true
done

sudo systemctl daemon-reload
sudo systemctl enable --now pi-fleet-watchdog.timer
log "filo kuruldu yedek=$BACKUP"
