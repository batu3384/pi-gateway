#!/usr/bin/env bash
# Hermes: SOUL.md + doğru pi-gateway-ops + Pi'de ölü skill disable.
# Eski ajan-yazması ops (Forgejo/Syncthing) ezilir. Container eklenmez.
set -euo pipefail
REMOTE_DIR="${REMOTE_DIR:-/home/${USER}/pi-gateway}"
HERMES_HOME="${HERMES_HOME:-$HOME/.hermes}"
SRC_SOUL="${REMOTE_DIR}/config/hermes/SOUL.md"
SRC_OPS="${REMOTE_DIR}/config/hermes/skills/pi-gateway-ops"
DST_OPS="${HERMES_HOME}/skills/smart-home/pi-gateway-ops"
log() { echo "[hermes-identity] $*"; }

[[ "${HERMES_TELEGRAM_GATEWAY:-}" == "true" ]] \
  || systemctl is-active --quiet hermes-gateway 2>/dev/null \
  || { log "Hermes yok — atlandi"; exit 0; }

[[ -f "$SRC_SOUL" ]] || { log "HATA: $SRC_SOUL yok"; exit 1; }
[[ -d "$SRC_OPS" ]] || { log "HATA: $SRC_OPS yok"; exit 1; }
mkdir -p "${HERMES_HOME}/skills/smart-home" "${HERMES_HOME}/memories"

# SOUL — kimlik (yedek al, sonra ez)
if [[ -f "${HERMES_HOME}/SOUL.md" ]]; then
  cp -a "${HERMES_HOME}/SOUL.md" "${HERMES_HOME}/SOUL.md.bak-pi-gateway" 2>/dev/null || true
fi
cp -a "$SRC_SOUL" "${HERMES_HOME}/SOUL.md"
chmod 600 "${HERMES_HOME}/SOUL.md" 2>/dev/null || true
log "OK SOUL.md"

# Ops skill — tek SSOT; eski server-ops kalıntısını sil
rm -rf "${HERMES_HOME}/skills/smart-home/pi-gateway-server-ops" \
  "${HERMES_HOME}/skills/pi-gateway-ops" \
  "${DST_OPS}"
mkdir -p "$(dirname "$DST_OPS")"
cp -a "$SRC_OPS" "$DST_OPS"
sed -i "s|__REMOTE_DIR__|${REMOTE_DIR}|g" "$DST_OPS/SKILL.md" 2>/dev/null \
  || sed -i '' "s|__REMOTE_DIR__|${REMOTE_DIR}|g" "$DST_OPS/SKILL.md"
log "OK pi-gateway-ops (server-ops silindi)"

# macOS / GPU / Pi'de yok skill'ler — config deny-list (hermes update silmez)
# shellcheck disable=SC2016
python3 - <<'PY'
import os
import pathlib
import tempfile
try:
    import yaml
except ImportError:
    raise SystemExit("yaml yok")

deny = [
    "imessage",
    "findmy",
    "apple-notes",
    "apple-reminders",
    "comfyui",
    "serving-llms-vllm",
    "llama-cpp",
    "openhue",
    "touchdesigner-mcp",
    "pi-gateway-server-ops",
    "paneller",
    "recover-ask",
]
hh = pathlib.Path(os.environ.get("HERMES_HOME") or (pathlib.Path.home() / ".hermes"))
cfg_path = hh / "config.yaml"
if not cfg_path.is_file():
    raise SystemExit(0)
raw_cfg = cfg_path.read_text()
data = yaml.safe_load(raw_cfg) or {}
skills = data.get("skills")
if not isinstance(skills, dict):
    skills = {}
    data["skills"] = skills
cur = skills.get("disabled")
if not isinstance(cur, list):
    cur = []
merged = list(dict.fromkeys([*cur, *deny]))
if merged == cur:
    raise SystemExit(0)
skills["disabled"] = merged
bak = cfg_path.with_suffix(".yaml.bak-skills-disabled")
bak.write_text(raw_cfg)
dumped = yaml.safe_dump(data, sort_keys=False, allow_unicode=True, default_flow_style=False)
fd, tmp_name = tempfile.mkstemp(prefix="config.yaml.tmp.", dir=str(cfg_path.parent))
try:
    with os.fdopen(fd, "w", encoding="utf-8") as fh:
        fh.write(dumped)
    os.chmod(tmp_name, 0o600)
    os.replace(tmp_name, cfg_path)
except Exception:
    try:
        os.unlink(tmp_name)
    except OSError:
        pass
    raise
print("OK skills.disabled +=", ",".join(deny))
PY
log "OK skills.disabled (ölü Pi skill)"

# MEMORY: wishlist / yanlis / siskin eski kayitlari sil; SSOT notu + <1400 char tavan
mem="${HERMES_HOME}/memories/MEMORY.md"
if [[ -f "$mem" ]]; then
  python3 - "$mem" <<'PY'
import os
import sys
import tempfile
from pathlib import Path

p = Path(sys.argv[1])
raw = p.read_text(errors="replace")
drop_markers = (
    "Proje kuyruğu",
    "Reklam engelleme projesi",
    "En Yaratıcı",
    "Waow",
    "engineering-report",
    "Mühendislik Analiz",
    "Vaultwarden, deprem",
    "fallback_dns",
    "1.1.1.1, 8.8.8.8",
    "/usr/local/lib",
    "manuel rsync",
    "07:00 sunucu durumu",
    "07:00'da sunucu",
)
parts = [b.strip() for b in raw.split("§") if b.strip()]
kept = []
seen = set()
for b in parts:
    if any(m.lower() in b.lower() for m in drop_markers):
        continue
    if "Pi Gateway yığın SSOT" in b:
        continue
    key = b.strip()
    if key in seen:
        continue
    seen.add(key)
    kept.append(key)
ssot = (
    "Pi Gateway yığın SSOT: AdGuard+Unbound+Caddy+Glance+Gatus+NetAlertX+CrowdSec+"
    "VictoriaMetrics/Grafana+restic+Hermes (n8n/Homepage/Kuma/Prometheus/Forgejo/Syncthing YOK). "
    "Detay: ~/.hermes/SOUL.md + skill pi-gateway-ops."
)
budget = 1400
# En eski non-SSOT kayitlari atarak 1400 char altinda kal
while kept and len("\n§\n".join([*kept, ssot]) + "\n") > budget:
    kept.pop(0)
kept.append(ssot)
new = "\n§\n".join(kept) + "\n"
if new != raw:
    p.with_suffix(".md.bak-wishlist-purge").write_text(raw)
    fd, tmp_name = tempfile.mkstemp(prefix="MEMORY.md.tmp.", dir=str(p.parent))
    try:
        with os.fdopen(fd, "w", encoding="utf-8") as fh:
            fh.write(new)
        os.chmod(tmp_name, 0o600)
        os.replace(tmp_name, p)
    except Exception:
        try:
            os.unlink(tmp_name)
        except OSError:
            pass
        raise
    print(f"OK MEMORY.md cleaned ({len(raw)} -> {len(new)} chars)")
else:
    print(f"skip MEMORY.md ({len(new)} chars)")
PY
  log "OK MEMORY wishlist purge" || log "skip MEMORY"
fi

log "Tamam — gateway restart önerilir (yeni SOUL)"
