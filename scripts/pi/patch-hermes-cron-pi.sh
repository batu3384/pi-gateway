#!/usr/bin/env bash
# Hermes cron: Pi Gateway hata mesajlari (Türkçe, anlasilir).
set -euo pipefail
log() { echo "[hermes-cron-patch] $*"; }

SCHEDULER="${HERMES_HOME:-$HOME/.hermes}/hermes-agent/cron/scheduler.py"
[[ -f "$SCHEDULER" ]] || { log "HATA: scheduler yok"; exit 1; }

python3 - "$SCHEDULER" <<'PY'
import pathlib, sys

path = pathlib.Path(sys.argv[1])
text = path.read_text()
marker = "# pi-gateway: no_agent cron failure summary"
if marker in text:
    print("unchanged")
    sys.exit(0)

needle = "    if len(cleaned) > 180:\n        cleaned = cleaned[:177].rstrip() + \"...\"\n    return f\"⚠️ Cron '{job_name}' failed: {cleaned}\""
if needle not in text:
    print("VERIFY_FAIL: anchor not found", file=sys.stderr)
    sys.exit(1)

insert = '''    if len(cleaned) > 180:
        cleaned = cleaned[:177].rstrip() + "..."
    # pi-gateway: no_agent cron failure summary
    if job.get("no_agent"):
        if "script path resolves outside" in lower or "blocked: script path" in lower:
            return (
                "📋 Pi Gateway · Zamanlanmış görev hatası\\n\\n"
                f"Görev: {job_name}\\n"
                "Sorun: Betik güvenlik dizini dışında (~/.hermes/scripts gerekli).\\n"
                "Çözüm: Pi\\'de REMOTE_DIR=~/pi-gateway bash scripts/pi/setup-hermes-cron-scripts.sh "
                "&& bash scripts/pi/setup-hermes-cron.sh && sudo systemctl restart hermes-gateway"
            )
        if lower.startswith("script not found"):
            return (
                "📋 Pi Gateway · Zamanlanmış görev hatası\\n\\n"
                f"Görev: {job_name}\\n"
                "Sorun: Betik dosyası bulunamadı.\\n"
                "Çözüm: setup-hermes-cron-scripts.sh + setup-hermes-cron.sh çalıştır."
            )
        if lower.startswith("script timed out"):
            return (
                "📋 Pi Gateway · Zamanlanmış görev hatası\\n\\n"
                f"Görev: {job_name}\\n"
                "Sorun: Betik süre aşımına uğradı (LLM çağrılmadı)."
            )
        if cleaned:
            return (
                "📋 Pi Gateway · Zamanlanmış görev hatası\\n\\n"
                f"Görev: {job_name}\\n"
                f"Detay: {cleaned}"
            )
    return f"⚠️ Cron '{job_name}' failed: {cleaned}"'''

text = text.replace(needle, insert, 1)
path.write_text(text)
print("patched")
PY

# Tekrarlayan basarisizlik uyarisi — Türkçe
python3 - "$SCHEDULER" <<'PY'
import pathlib, sys

path = pathlib.Path(sys.argv[1])
text = path.read_text()
marker = "pi-gateway: failure nudge tr"
if marker in text:
    print("nudge unchanged")
    sys.exit(0)

old = (
    '    return (\n'
    '        f"\\nThis job has failed {streak} runs in a row — worth a review. "\n'
    '        f"Fix its prompt/config, or pause it with `hermes cron pause {job_ref}` "\n'
    '        "(resume/remove also available) to stop the noise."\n'
    '    )'
)
new = (
    '    # pi-gateway: failure nudge tr\n'
    '    return (\n'
    '        f"\\n\\n—\\n"\n'
    '        f"⚠️ Bu görev üst üste {streak} kez başarısız oldu. "\n'
    '        f"Durdurmak için: hermes cron pause \\"{job_ref}\\""\n'
    '    )'
)
if old not in text:
    print("VERIFY_FAIL: nudge anchor not found", file=sys.stderr)
    sys.exit(1)
path.write_text(text.replace(old, new, 1))
print("nudge patched")
PY

log "Tamamlandi"
