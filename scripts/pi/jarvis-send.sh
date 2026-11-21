#!/usr/bin/env bash
# Jarvis (OpenBot native) — host automation API. Push = tur bitince (isteğe bağlı --wait).
set -euo pipefail
REMOTE_DIR="${REMOTE_DIR:-/home/${USER}/pi-gateway}"
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=../lib/openbot-paths.sh
source "${SCRIPT_DIR}/../lib/openbot-paths.sh"
JARVIS_AGENT_ID="${JARVIS_AGENT_ID:-}"
JARVIS_AGENT_NAME="${JARVIS_AGENT_NAME:-Jarvis}"

WAIT=0
TIMEOUT_SEC="${OPENBOT_ALERT_WAIT_SEC:-120}"
CLIENT_MSG_ID=""
JSON_OUT=0

usage() {
  echo "Kullanım: $0 [--wait] [--timeout SEC] [--id clientMessageId] [--json] <metin|--file path>" >&2
  exit 2
}

while [[ $# -gt 0 ]]; do
  case "$1" in
    --wait) WAIT=1; shift ;;
    --timeout)
      [[ -n "${2:-}" ]] || usage
      TIMEOUT_SEC="$2"
      shift 2
      ;;
    --id)
      [[ -n "${2:-}" ]] || usage
      CLIENT_MSG_ID="$2"
      shift 2
      ;;
    --json) JSON_OUT=1; shift ;;
    --file)
      [[ -n "${2:-}" && -f "${2:-}" ]] || usage
      text="$(cat "$2")"
      shift 2
      break
      ;;
    -h|--help) usage ;;
    *)
      if [[ -n "${text:-}" ]]; then
        text="$text $1"
      else
        text="$1"
      fi
      shift
      ;;
  esac
done

if [[ -z "${text:-}" && $# -gt 0 ]]; then
  text="$*"
fi

if [[ -z "${text:-}" ]]; then
  usage
fi

[[ -n "$text" ]] || exit 0

AUTO_DIR="$(openbot_automation_dir)"
_db="$(openbot_db_path)"

if [[ -z "$JARVIS_AGENT_ID" ]]; then
  JARVIS_AGENT_ID="$(JARVIS_AGENT_NAME="$JARVIS_AGENT_NAME" python3 - "$_db" <<'PY'
import json, os, sqlite3, sys
db = sys.argv[1]
want = os.environ.get("JARVIS_AGENT_NAME", "Jarvis")
con = sqlite3.connect(f"file:{db}?mode=ro", uri=True)
rows = [json.loads(blob) for (blob,) in con.execute("select agent_json from projection_agents")]
match = [a for a in rows if a.get("name") == want]
if len(match) == 1:
    print(match[0]["id"])
elif len(rows) == 1:
    print(rows[0]["id"])
else:
    sys.exit(1)
PY
)"
fi
[[ "$JARVIS_AGENT_ID" =~ ^agent-[0-9a-f-]{36}$ ]] || {
  echo "[jarvis-send] geçersiz agent id" >&2
  exit 1
}

_wait_iters="${JARVIS_AUTOMATION_WAIT_ITERS:-15}"
for _ in $(seq 1 "$_wait_iters"); do
  [[ -f "${AUTO_DIR}/url" && -f "${AUTO_DIR}/headers" ]] && break
  sleep 2
done
[[ -f "${AUTO_DIR}/url" && -f "${AUTO_DIR}/headers" ]] || {
  echo "[jarvis-send] automation hazır değil (openbot.service çalışıyor mu?)" >&2
  exit 1
}

base="$(tr -d '\n' <"${AUTO_DIR}/url")"
[[ "$base" =~ ^http://127\.0\.0\.1:[0-9]{1,5}$ ]] || {
  echo "[jarvis-send] automation url loopback değil" >&2
  exit 1
}
payload="$(mktemp)"
receipt="$(mktemp)"
trap 'rm -f "$payload" "$receipt"' EXIT

CLIENT_MSG_ID="$CLIENT_MSG_ID" JARVIS_TEXT="$text" python3 - "$payload" <<'PY'
import json, os, sys, uuid
text = os.environ["JARVIS_TEXT"]
cid = (os.environ.get("CLIENT_MSG_ID") or "").strip()
if not cid:
    cid = str(uuid.uuid4())
elif len(cid) > 128:
    cid = cid[:128]
if len(text) > 12000:
    text = text[:12000] + "\n…"
payload = {"text": text, "clientMessageId": cid}
with open(sys.argv[1], "w", encoding="utf-8") as fh:
    json.dump(payload, fh, ensure_ascii=False)
PY

curl -fsS --connect-timeout 5 --max-time 30 --proto '=http' --max-redirs 0 -X POST "${base}/v1/agents/${JARVIS_AGENT_ID}/messages" \
  -H @"${AUTO_DIR}/headers" \
  -H "Content-Type: application/json" \
  --data-binary @"$payload" >"$receipt"

if [[ "$JSON_OUT" -eq 1 ]]; then
  cat "$receipt"
fi

if [[ "$WAIT" -eq 0 ]]; then
  exit 0
fi

WAIT_TIMEOUT="$TIMEOUT_SEC" JARVIS_AGENT_ID="$JARVIS_AGENT_ID" \
  AUTO_DIR="$AUTO_DIR" BASE_URL="$base" RECEIPT_PATH="$receipt" python3 - <<'PY'
import json, os, sys, time, urllib.error, urllib.request

timeout = float(os.environ.get("WAIT_TIMEOUT", "120"))
agent_id = os.environ["JARVIS_AGENT_ID"]
base = os.environ["BASE_URL"].rstrip("/")
receipt_path = os.environ["RECEIPT_PATH"]
auto_dir = os.environ["AUTO_DIR"]

with open(f"{auto_dir}/headers", encoding="utf-8") as fh:
    auth_lines = [ln.strip() for ln in fh if ln.strip()]
headers = {ln.split(":", 1)[0].strip(): ln.split(":", 1)[1].strip() for ln in auth_lines if ":" in ln}

data = json.load(open(receipt_path, encoding="utf-8"))
deliveries = data.get("deliveries") or []
if not deliveries:
    print("[jarvis-send] delivery yok", file=sys.stderr)
    sys.exit(1)
delivery_id = deliveries[0].get("id")
if not delivery_id:
    print("[jarvis-send] delivery id yok", file=sys.stderr)
    sys.exit(1)

url = f"{base}/v1/agents/{agent_id}/deliveries/{delivery_id}"
deadline = time.time() + timeout
last_status = ""

class _NoRedirect(urllib.request.HTTPRedirectHandler):
    def redirect_request(self, req, fp, code, msg, headers, newurl):
        raise urllib.error.HTTPError(req.full_url, code, "redirect reddedildi", headers, fp)

def fetch():
    req = urllib.request.Request(url, headers=headers, method="GET")
    opener = urllib.request.build_opener(_NoRedirect)
    with opener.open(req, timeout=15) as resp:
        return json.loads(resp.read().decode())

while time.time() < deadline:
    try:
        body = fetch()
    except urllib.error.HTTPError as e:
        print(f"[jarvis-send] poll HTTP {e.code}", file=sys.stderr)
        time.sleep(2)
        continue
    except urllib.error.URLError as e:
        print(f"[jarvis-send] poll: {e}", file=sys.stderr)
        time.sleep(2)
        continue
    status = body.get("status") or ""
    last_status = status
    if status == "completed":
        ans = (body.get("answer") or "").strip()
        if ans:
            print(ans)
        sys.exit(0)
    if status in ("failed", "cancelled", "interrupted"):
        err = body.get("error") or status
        print(f"[jarvis-send] delivery {status}: {err}", file=sys.stderr)
        sys.exit(1)
    time.sleep(2)

print(f"[jarvis-send] zaman aşımı ({int(timeout)}s), son durum={last_status}", file=sys.stderr)
sys.exit(1)
PY