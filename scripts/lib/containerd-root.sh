# containerd data root helpers (Docker 29+ snapshotter store)
CONTAINERD_CONFIG="${CONTAINERD_CONFIG:-/etc/containerd/config.toml}"
CONTAINERD_LEGACY_ROOT="${CONTAINERD_LEGACY_ROOT:-/var/lib/containerd}"

containerd_root_from_config() {
  grep -E '^root\s*=' "$CONTAINERD_CONFIG" 2>/dev/null \
    | head -1 | sed -n 's/.*"\([^"]*\)".*/\1/p'
}

set_containerd_root() {
  local root="$1"
  sudo python3 - "$CONTAINERD_CONFIG" "$root" <<'PY'
import re, sys
from pathlib import Path
path, root = Path(sys.argv[1]), sys.argv[2]
text = path.read_text() if path.exists() else ""
line = f'root = "{root}"'
if re.search(r'^#?root\s*=', text, flags=re.M):
    text = re.sub(r'^#?root\s*=.*', line, text, flags=re.M)
else:
    text = f'version = 2\n{line}\n{text}'
path.write_text(text)
PY
}
