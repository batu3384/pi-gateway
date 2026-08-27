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
import pathlib
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
]
cfg_path = pathlib.Path.home() / ".hermes" / "config.yaml"
if not cfg_path.is_file():
    raise SystemExit(0)
data = yaml.safe_load(cfg_path.read_text()) or {}
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
bak.write_text(cfg_path.read_text())
cfg_path.write_text(
    yaml.safe_dump(data, sort_keys=False, allow_unicode=True, default_flow_style=False)
)
print("OK skills.disabled +=", ",".join(deny))
PY
log "OK skills.disabled (ölü Pi skill)"

# MEMORY: wishlist / eski rapor kuyruğunu sil; SSOT notu bırak
mem="${HERMES_HOME}/memories/MEMORY.md"
if [[ -f "$mem" ]]; then
  python3 - <<'PY'
from pathlib import Path
p = Path.home() / ".hermes" / "memories" / "MEMORY.md"
raw = p.read_text(errors="replace")
drop_prefixes = (
    "Proje kuyruğu",
    "Reklam engelleme projesi",
    "En Yaratıcı",
    "Waow",
    "engineering-report",
    "Mühendislik Analiz",
)
parts = [b.strip() for b in raw.split("§") if b.strip()]
kept = []
for b in parts:
    if any(b.startswith(d) or d in b[:80] for d in drop_prefixes):
        continue
    if "Proje kuyruğu:" in b or "Vaultwarden, deprem" in b:
        continue
    kept.append(b)
ssot = (
    "Pi Gateway yığın SSOT: AdGuard+Unbound+Caddy+n8n+NetAlertX+CrowdSec+"
    "Prometheus/Grafana+restic+Hermes. Forgejo/Syncthing YOK. "
    "Özellik wishlist yok. Detay: ~/.hermes/SOUL.md + skill pi-gateway-ops."
)
kept = [b for b in kept if "Pi Gateway yığın SSOT" not in b]
kept.append(ssot)
new = "\n§\n".join(kept) + "\n"
if new != raw:
    p.with_suffix(".md.bak-wishlist-purge").write_text(raw)
    p.write_text(new)
    print("OK MEMORY.md wishlist purge")
else:
    print("skip MEMORY.md")
PY
  log "OK MEMORY wishlist purge" || log "skip MEMORY"
fi

log "Tamam — gateway restart önerilir (yeni SOUL)"
