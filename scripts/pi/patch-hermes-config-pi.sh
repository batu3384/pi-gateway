#!/usr/bin/env bash
# Hermes config: cron/bülten timeout ve z.ai stale_timeout (Pi).
set -euo pipefail
REMOTE_DIR="${REMOTE_DIR:-/home/${USER}/pi-gateway}"
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
_PG_ENV_LIB="${SCRIPT_DIR}/../lib/env-file.sh"
PG_SCRIPT_NAME="$(basename "$0")"
# shellcheck source=../lib/env-file.sh
source "${_PG_ENV_LIB:?}"
read_remote_dotenv || { echo "[${PG_SCRIPT_NAME}] HATA: .env dotenv parser hatasi" >&2; exit 1; }
log() { echo "[hermes-config-patch] $*"; }

if [[ "${HERMES_TELEGRAM_GATEWAY:-}" != "true" ]] \
  && systemctl is-active --quiet hermes-gateway 2>/dev/null; then
  export HERMES_TELEGRAM_GATEWAY=true
fi
[[ "${HERMES_TELEGRAM_GATEWAY:-}" == "true" ]] || { log "HERMES_TELEGRAM_GATEWAY!=true — atlandi"; exit 0; }

hermes_bin="${HOME}/.local/bin/hermes"
[[ -x "$hermes_bin" ]] || { log "hermes yok — atlandi"; exit 0; }

CFG_CHANGED=0
# Nokta = path. Model id (glm-5.3) hermes config set ile yazma — walker glm-5/3 yapar.
yaml_same() {
  python3 -c '
import pathlib, sys
key, want = sys.argv[1], sys.argv[2]
try:
    import yaml
except ImportError:
    raise SystemExit(1)
p = pathlib.Path.home() / ".hermes" / "config.yaml"
if not p.is_file():
    raise SystemExit(1)
cur = yaml.safe_load(p.read_text()) or {}
for part in key.split("."):
    if not isinstance(cur, dict) or part not in cur:
        raise SystemExit(1)
    cur = cur[part]

def norm(x):
    if isinstance(x, bool):
        return "true" if x else "false"
    if isinstance(x, (int, float)):
        f = float(x)
        return str(int(f)) if f == int(f) else str(x)
    return str(x).strip().lower()

raise SystemExit(0 if norm(cur) == norm(want) else 1)
' "$1" "$2"
}

set_cfg() {
  local key="$1" val="$2"
  if yaml_same "$key" "$val"; then
    log "skip $key=$val"
    return 0
  fi
  if "$hermes_bin" config set "$key" "$val" >/dev/null 2>&1; then
    log "OK $key=$val"
    CFG_CHANGED=1
  else
    log "WARN: $key ayarlanamadi"
  fi
}

# glm-5.3 nokta tuzağı: models['glm-5']['3'] çöpü. Stale provider seviyesinde.
export HERMES_STALE_TIMEOUT_SEC="${HERMES_STALE_TIMEOUT_SEC:-600}"
if python3 - <<'PY'
import os
import pathlib

try:
    import yaml
except ImportError:
    raise SystemExit(1)
p = pathlib.Path.home() / ".hermes" / "config.yaml"
if not p.is_file():
    raise SystemExit(1)
data = yaml.safe_load(p.read_text()) or {}
changed = False
providers = data.get("providers")
if not isinstance(providers, dict):
    raise SystemExit(1)
zai = providers.get("zai")
if not isinstance(zai, dict):
    raise SystemExit(1)
models = zai.get("models")
if isinstance(models, dict):
    g5 = models.get("glm-5")
    if isinstance(g5, dict) and "3" in g5:
        g5.pop("3", None)
        if not g5:
            del models["glm-5"]
        changed = True
try:
    want = int(os.environ.get("HERMES_STALE_TIMEOUT_SEC", "600"))
except ValueError:
    want = 600
if zai.get("stale_timeout_seconds") != want:
    zai["stale_timeout_seconds"] = want
    changed = True
if not changed:
    raise SystemExit(1)
p.with_name("config.yaml.bak-unsplit").write_text(p.read_text())
p.write_text(yaml.safe_dump(data, sort_keys=False, allow_unicode=True, default_flow_style=False))
raise SystemExit(0)
PY
then
  CFG_CHANGED=1
  log "OK providers.zai.stale_timeout_seconds + glm-5/3 unsplit"
else
  log "skip providers.zai.stale_timeout_seconds"
fi
set_cfg "cron.bot_chat_delivery_timeout_seconds" "${HERMES_CRON_DELIVERY_TIMEOUT_SEC:-900}"
set_cfg "model.inactivity_timeout" "${HERMES_MODEL_INACTIVITY_TIMEOUT:-300}"
set_cfg "model.timeout" "${HERMES_MODEL_TIMEOUT:-300}"
set_cfg "code_execution.max_tool_calls" "${HERMES_MAX_TOOL_CALLS:-45}"
# GLM API stream açık kalsın (cron 90s non-stream timeout). Telegram editMessageText ayrı.
set_cfg "streaming.enabled" "${HERMES_STREAMING:-true}"
set_cfg "display.platforms.telegram.streaming" "${HERMES_TELEGRAM_STREAMING:-false}"
_tp="${HERMES_TELEGRAM_TOOL_PROGRESS:-off}"
case "${_tp}" in off|false|0|no) _tp=false ;; on|true|1|yes) _tp=true ;; esac
set_cfg "display.platforms.telegram.tool_progress" "$_tp"
set_cfg "cron.wrap_response" "false"
# GLM-5.3 1M → %50 hiç ateşlenmez. 96k: akşam bülten ~71k sığar, sohbet yine tavanlı.
_compress_cap="${HERMES_COMPRESS_TOKEN_CAP:-96000}"
set_cfg "compression.threshold_tokens" "$_compress_cap"
set_cfg "compression.proactive_prune_tokens" "${HERMES_COMPRESS_PRUNE_TOKENS:-$_compress_cap}"
set_cfg "compression.hygiene_hard_message_limit" "${HERMES_COMPRESS_MSG_LIMIT:-180}"
set_cfg "compression.idle_compact_after_seconds" "${HERMES_IDLE_COMPACT_SEC:-1800}"
set_cfg "compression.protect_last_n" "${HERMES_COMPRESS_PROTECT_N:-12}"
set_cfg "session_reset.mode" "${HERMES_SESSION_RESET_MODE:-both}"
set_cfg "session_reset.at_hour" "${HERMES_SESSION_RESET_HOUR:-4}"
set_cfg "session_reset.idle_minutes" "${HERMES_SESSION_IDLE_MIN:-720}"
set_cfg "session_reset.notify" "${HERMES_SESSION_RESET_NOTIFY:-false}"
# Unutulmuş background process 04:00 reset'i kilitlemesin (#29177). Process öldürülmez.
set_cfg "session_reset.bg_process_max_age_hours" "${HERMES_SESSION_BG_MAX_AGE_H:-2}"
set_cfg "code_execution.loop_caps.max_web_searches" "${HERMES_MAX_WEB_SEARCHES:-6}"
set_cfg "code_execution.loop_caps.max_web_extracts" "${HERMES_MAX_WEB_EXTRACTS:-8}"

# /menu skill Telegram / menüsünde görünsün (cap yüzünden skill'ler düşüyordu)
_menu_prio_py="${SCRIPT_DIR}/../lib/hermes-telegram-menu-priority.py"
if [[ -f "$_menu_prio_py" ]]; then
  if python3 "$_menu_prio_py"; then
    CFG_CHANGED=1
    log "OK platforms.telegram.extra.command_menu priority += menu"
  else
    log "skip command_menu priority"
  fi
fi

hermes_py="${HOME}/.hermes/hermes-agent/venv/bin/python"
ddgs_ok=0
if [[ -x "$hermes_py" ]]; then
  if "$hermes_py" -c "import ddgs" >/dev/null 2>&1; then
    ddgs_ok=1
    log "OK ddgs zaten var"
  else
    log "ddgs kuruluyor (Firecrawl keyless 403 yerine)"
    if "$hermes_py" -m pip install -q "ddgs>=9.0,<10" \
      && "$hermes_py" -c "import ddgs" >/dev/null 2>&1; then
      ddgs_ok=1
      log "OK ddgs"
    else
      log "WARN: ddgs pip/import basarisiz — search_backend degistirilmedi"
    fi
  fi
else
  log "WARN: hermes venv python yok — ddgs atlandi"
fi
if [[ "$ddgs_ok" -eq 1 ]]; then
  set_cfg "web.search_backend" "ddgs"
else
  log "WARN: web.search_backend=ddgs yazilmadi (paket yok)"
fi

hygiene_py="${SCRIPT_DIR}/../lib/hermes-session-hygiene.py"
if [[ -f "$hygiene_py" ]]; then
  _idle_sec=$(( ${HERMES_SESSION_IDLE_MIN:-720} * 60 ))
  python3 "$hygiene_py" --idle-seconds "$_idle_sec" \
    || log "WARN: session hygiene atlandi"
fi
# Hygiene SQLite end yeter (#54878). Restart yalnız gerçek config değişince.
if [[ "$CFG_CHANGED" -eq 1 ]] && systemctl is-active --quiet hermes-gateway 2>/dev/null; then
  sudo systemctl restart hermes-gateway \
    && log "OK hermes-gateway restart (config degisti)" \
    || log "WARN: hermes-gateway restart basarisiz"
elif [[ "$CFG_CHANGED" -eq 0 ]]; then
  log "skip hermes-gateway restart (config ayni)"
fi

log "Tamamlandi"
