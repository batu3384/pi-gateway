#!/usr/bin/env bash
# Idempotent Pi workarounds for Hermes Telegram adapter (v0.20.x).
# Upstream: cold-start progress gate + Application.initialize() can wedge
# forever on this host (_await_with_thread_deadline never fires while a
# getUpdates long-poll is open). Re-run after `hermes update`.
# Exit 1 if required markers missing after apply (no false already-applied).
set -euo pipefail
log() { echo "[hermes-tg-patch] $*"; }

ADAPTER="${HERMES_HOME:-$HOME/.hermes}/hermes-agent/plugins/platforms/telegram/adapter.py"
[[ -f "$ADAPTER" ]] || { log "HATA: adapter yok: $ADAPTER"; exit 1; }

python3 - "$ADAPTER" <<'PY'
import pathlib, sys

path = pathlib.Path(sys.argv[1])
text = path.read_text()
orig = text
changed = []

MARKER_REQ = "require_progress=False"
MARKER_STEP = "pi-gateway: stepped initialize"
MARKER_CONN = 'logger.warning("[%s] Connected to Telegram (%s mode)"'

def verified(t: str) -> bool:
    return MARKER_REQ in t and MARKER_STEP in t

# 1) Cold-start: do not wait forever for getUpdates progress gate
old_req = "require_progress=not is_reconnect,"
new_req = "require_progress=False,  # pi-gateway: progress gate wedges (#67498 class)"
if MARKER_REQ not in text and old_req in text:
    text = text.replace(old_req, new_req, 1)
    changed.append("require_progress=False")
elif MARKER_REQ not in text and "require_progress=False" in text:
    pass  # already False somehow
elif MARKER_REQ not in text and old_req not in text:
    # Accept existing Pi debug patch that set require_progress=False without comment
    if "require_progress=False" in text:
        pass

# Normalize: if False present without our comment, still OK for MARKER_REQ
# MARKER_REQ is substring of require_progress=False

# 2) Stepped initialize instead of wall-clock thread deadline on initialize
needle = """                    await _await_with_thread_deadline(
                        self._app.initialize(),
                        timeout=_init_timeout,"""
if MARKER_STEP not in text and needle in text:
    start = text.find(needle)
    end = text.find("                    )", start)
    if end < 0:
        raise SystemExit("initialize deadline block end not found")
    end = text.find("\n", end) + 1
    replacement = '''                    # pi-gateway: stepped initialize
                    async def _pi_stepped_initialize(app):
                        await app.bot.initialize()
                        await app._update_processor.initialize()
                        if app.updater:
                            await app.updater.initialize()
                        if app.persistence:
                            await app._initialize_persistence()
                            from telegram.ext._handlers.conversationhandler import ConversationHandler
                            import itertools
                            for handler in itertools.chain.from_iterable(app.handlers.values()):
                                if isinstance(handler, ConversationHandler) and handler.persistent and handler.name:
                                    await app._add_ch_to_persistence(handler)
                            app._initialized = True
                            app._Application__stop_running_marker.clear()
                        else:
                            app._initialized = True

                    try:
                        await asyncio.wait_for(
                            _pi_stepped_initialize(self._app),
                            timeout=_init_timeout,
                        )
                    except asyncio.TimeoutError:
                        try:
                            await _shutdown_abandoned_app(self._app)
                        except Exception:
                            pass
                        raise
'''
    text = text[:start] + replacement + text[end:]
    changed.append("stepped-initialize")
elif MARKER_STEP not in text:
    # Accept prior live debug names
    if "_pi_stepped_initialize" in text or "_stepped_initialize" in text:
        # Stamp canonical marker comment if missing
        if "# pi-gateway: stepped initialize" not in text:
            text = text.replace(
                "async def _stepped_initialize(app):",
                "# pi-gateway: stepped initialize\n                    async def _stepped_initialize(app):",
                1,
            )
            if "# pi-gateway: stepped initialize" not in text:
                text = text.replace(
                    "async def _pi_stepped_initialize(app):",
                    "# pi-gateway: stepped initialize\n                    async def _pi_stepped_initialize(app):",
                    1,
                )
            if MARKER_STEP in text:
                changed.append("stamp-step-marker")

# 3) Surface connect success at WARNING
old_conn = 'logger.info("[%s] Connected to Telegram (%s mode)", self.name, mode)'
new_conn = 'logger.warning("[%s] Connected to Telegram (%s mode)", self.name, mode)'
if old_conn in text:
    text = text.replace(old_conn, new_conn, 1)
    changed.append("connected-warning")

if text != orig:
    path.write_text(text)
    print("patched:" + ",".join(changed) if changed else "patched:touch")
else:
    print("unchanged")

final = path.read_text()
ok_req = "require_progress=False" in final
ok_step = (
    MARKER_STEP in final
    or "_pi_stepped_initialize" in final
    or ("_stepped_initialize" in final and "asyncio.wait_for" in final)
)
if not (ok_req and ok_step):
    missing = []
    if not ok_req:
        missing.append("require_progress=False")
    if not ok_step:
        missing.append("stepped-initialize")
    print("VERIFY_FAIL missing=" + ",".join(missing), file=sys.stderr)
    raise SystemExit(1)
print("verified")
PY

# Dual-stack Happy-Eyeballs hang (#87015): pin Telegram API to known IPv4
if ! grep -qE '^[[:space:]]*149\.154\.166\.110[[:space:]]+api\.telegram\.org' /etc/hosts 2>/dev/null; then
  echo '149.154.166.110 api.telegram.org' | sudo tee -a /etc/hosts >/dev/null
  log "hosts: api.telegram.org -> 149.154.166.110"
fi

drop=/etc/systemd/system/hermes-gateway.service.d
sudo mkdir -p "$drop"
# Pi aarch64: Chrome-for-Testing yok → sistem Chromium
chrome=""
for p in /usr/bin/chromium /usr/bin/chromium-browser; do
  [[ -x "$p" ]] && chrome=$p && break
done
{
  echo '[Service]'
  echo 'Environment=PYTHONUNBUFFERED=1'
  echo 'Environment=HERMES_TELEGRAM_DISABLE_FALLBACK_IPS=1'
  echo 'Environment=HERMES_TELEGRAM_HTTP_POOL_SIZE=8'
  echo 'Environment=HERMES_TELEGRAM_INIT_TIMEOUT=30'
  if [[ -n "$chrome" ]]; then
    echo "Environment=AGENT_BROWSER_EXECUTABLE_PATH=$chrome"
    echo "Environment=PLAYWRIGHT_CHROMIUM_EXECUTABLE_PATH=$chrome"
  fi
} | sudo tee "$drop/override.conf" >/dev/null
if [[ -n "$chrome" ]]; then
  envf="${HERMES_HOME:-$HOME/.hermes}/.env"
  if [[ -f "$envf" ]]; then
    grep -q '^AGENT_BROWSER_EXECUTABLE_PATH=' "$envf" && \
      sed -i "s|^AGENT_BROWSER_EXECUTABLE_PATH=.*|AGENT_BROWSER_EXECUTABLE_PATH=$chrome|" "$envf" || \
      echo "AGENT_BROWSER_EXECUTABLE_PATH=$chrome" >> "$envf"
    grep -q '^PLAYWRIGHT_CHROMIUM_EXECUTABLE_PATH=' "$envf" && \
      sed -i "s|^PLAYWRIGHT_CHROMIUM_EXECUTABLE_PATH=.*|PLAYWRIGHT_CHROMIUM_EXECUTABLE_PATH=$chrome|" "$envf" || \
      echo "PLAYWRIGHT_CHROMIUM_EXECUTABLE_PATH=$chrome" >> "$envf"
  fi
  log "browser: $chrome"
fi
sudo systemctl daemon-reload
log "drop-in OK; setup-hermes-gateway restart eder"
