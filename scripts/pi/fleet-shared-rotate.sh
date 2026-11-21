#!/usr/bin/env bash
# OpenBot fleet/shared/*.md rolling arşivleme (sıfır LLM, atomik).
# Dosya FLEET_SHARED_MAX_LINES satırı aşarsa üst başlığı korur, eski satırları archive/YYYY-MM/'e taşır.
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REMOTE_DIR="${REMOTE_DIR:-/home/${USER:-pi}/pi-gateway}"

if [[ "${1:-}" == "--self-check" ]]; then
  tmp_root="$(mktemp -d)"
  trap 'rm -rf "$tmp_root"' EXIT
  mkdir -p "$tmp_root/shared"
  {
    echo "# tech_radar.md"
    echo ""
    echo "Yazıcı: Falcon"
    echo "Okur: Spider, Ultron, Iron"
    echo ""
    for i in $(seq 1 25); do
      echo "- 2026-11-21: Kayıt ${i}"
    done
  } >"$tmp_root/shared/tech_radar.md"
  FLEET_SHARED_MAX_LINES=10 OPENBOT_FLEET_ROOT="$tmp_root" bash "$0" >/dev/null
  live_lines="$(wc -l <"$tmp_root/shared/tech_radar.md" | tr -d ' ')"
  arch_count="$(find "$tmp_root/shared/archive" -name 'tech_radar.md' -type f | wc -l | tr -d ' ')"
  [[ "$live_lines" -le 16 && "$arch_count" -eq 1 ]] || {
    echo "[fleet-shared-rotate] self-check FAIL live=$live_lines arch=$arch_count" >&2
    exit 1
  }
  grep -q '^# tech_radar.md$' "$tmp_root/shared/tech_radar.md" || {
    echo "[fleet-shared-rotate] header kayboldu" >&2
    exit 1
  }
  echo "[fleet-shared-rotate] self-check OK"
  exit 0
fi

if [[ -f "${SCRIPT_DIR}/../lib/openbot-paths.sh" ]]; then
  # shellcheck source=../lib/openbot-paths.sh
  source "${SCRIPT_DIR}/../lib/openbot-paths.sh"
  FLEET="${OPENBOT_FLEET_ROOT:-$(openbot_data_root)/fleet}"
else
  FLEET="${OPENBOT_FLEET_ROOT:-/mnt/ssd/openbot-native/fleet}"
fi

SHARED_DIR="${FLEET}/shared"
MAX_LINES="${FLEET_SHARED_MAX_LINES:-120}"
[[ -d "$SHARED_DIR" ]] || exit 0

SHARED_DIR="$SHARED_DIR" MAX_LINES="$MAX_LINES" python3 - <<'PY'
import os
import tempfile
from datetime import datetime, timezone
from pathlib import Path

shared = Path(os.environ["SHARED_DIR"])
max_lines = max(10, int(os.environ.get("MAX_LINES", "120")))
month = datetime.now(timezone.utc).strftime("%Y-%m")
targets = (
    "system_health.md",
    "tech_radar.md",
    "english_log.md",
    "career_pipeline.md",
    "culture_library.md",
)

def split_header_body(lines: list[str]) -> tuple[list[str], list[str]]:
    # Header = initial title/metadata/table-header block before first data entry (##, -, or data table row)
    for idx, ln in enumerate(lines):
        s = ln.strip()
        if idx == 0:
            continue
        if s.startswith("## ") or s.startswith("- "):
            return lines[:idx], lines[idx:]
        if s.startswith("|---") or s.startswith("| ---"):
            return lines[: idx + 1], lines[idx + 1 :]
    return lines[:5], lines[5:]

rotated = 0
for name in targets:
    p = shared / name
    if not p.is_file():
        continue
    lines = p.read_text(encoding="utf-8", errors="replace").splitlines(keepends=True)
    header, body = split_header_body(lines)
    if len(body) <= max_lines:
        continue
    overflow = body[:-max_lines]
    kept = header + body[-max_lines:]
    arch_dir = shared / "archive" / month
    arch_dir.mkdir(parents=True, exist_ok=True)
    arch_file = arch_dir / name
    with open(arch_file, "a", encoding="utf-8") as af:
        af.writelines(overflow)
    fd, tmp_name = tempfile.mkstemp(prefix=f".{name}.", dir=str(shared))
    try:
        with os.fdopen(fd, "w", encoding="utf-8") as tf:
            tf.writelines(kept)
        os.chmod(tmp_name, 0o664)
        os.replace(tmp_name, p)
    except Exception:
        try:
            os.unlink(tmp_name)
        except OSError:
            pass
        raise
    rotated += 1
    print(f"[fleet-shared-rotate] {name}: archived={len(overflow)} kept={len(kept)}")

if rotated == 0:
    print("[fleet-shared-rotate] OK (rotasyon gerekmedi)")
PY
